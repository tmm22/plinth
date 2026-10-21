# Slant 3D V2 API integration reference

Verified 18 October 2026 from [official documentation](https://slant3dapi.com/documentation/introduction) (docs SPA bundle `assets/index-DSzyXtco.js`), and [official OpenAPI](https://slant3dapi.com/v2/api/openapi.json). The bundled `Sources/SlantStudio/Resources/openapi.json` is the official spec plus doc-backed supplements marked with `x-slant-studio-source: docs`.

## Connection and prerequisites

- Production base: `https://slant3dapi.com/v2/api`. Bearer API key in `Authorization`, JSON bodies with `Content-Type: application/json`. Do not send bearer credentials to presigned storage URLs.
- Exception: `POST /slant/webhook` uses `https://slant3dapi.com/v2/slant/webhook`, outside the `/api` prefix (operation-specific server in OpenAPI).
- Rate limit: **100 requests/minute** per API key. Response headers: `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset` (unix), `X-RateLimit-Role`. OpenSCAD: **5 generations/hour**, one in flight. Up to three API keys and five enabled platforms. No public sandbox.
- Most workflows require an owned platform. Drafting does not charge; processing charges and starts production. Key creation/listing (`/apiKey`) is session-only (dashboard).

## Upload and manufacture

1. `POST /files/direct-upload` with `name`, `platformId` required; `ownerId` optional; `type` optional `stl` | `3mf` | `obj` (default `stl`). File records and `POST /files` use the same type set.
2. PUT raw bytes to `data.presignedUrl` without Authorization; retain `data.filePlaceholder` unchanged.
3. `POST /files/confirm-upload` with `{ "filePlaceholder": <exact object> }`. Identifier is `publicFileServiceId`. Prefer `metrics` over deprecated `STLMetrics`.
4. Estimate with `POST /files/{publicFileId}/estimate`. Draft with `platformId`, customer details/address, and items.
5. Draft response `data` shape (docs): `{ order, items, totals: { printingCost, deliveryCost, totalCost }, customer }`.
6. Process with `POST /orders/{publicOrderId}`; cancel with `DELETE` (see refund note below). OpenSCAD returns raw STL bytes (`application/sla`).

## Delivery address defaults and lookup

The guided order composer defaults the shipping country from the Mac’s Region setting, with delivery details reused from the current session taking priority. Region is an editable default, not physical-location detection.

**Use current location** is an optional client-side Apple Core Location and reverse-geocoding flow, not a Slant endpoint. It requests permission only after the button is pressed and offers a suggested street address for review. **Use this address** replaces shipping fields, clears the old apartment/unit number, and retains name and email. Coordinates are not added to the Slant order payload or activity log. The reviewed address is sent through the normal order-draft request when the user creates the draft.

The app rejects fixes older than 60 seconds or with horizontal uncertainty over 100 metres, and stops lookup after 45 seconds. These are app heuristics, not delivery-address verification. Missing street/country information, lookup errors and denied permission leave manual entry available. See `DeliveryLocation.swift` and the permission descriptions in `scripts/build-app.sh`.

## Orders, fulfillment, cancel / refund

- **Full status enum** (bundled schema): `DRAFT`, `PAID`, `QUEUED`, `PROCESSING`, `PRINTING`, `ITEMS_ON_SHELF`, `POST_PROCESSING`, `COMPLETED`, `IN_REVIEW`, `AWAITING_SHIPMENT`, `SHIPPED`, `DELIVERED`, `CANCELED`, `PAYMENT_ERROR`. Docs lifecycle highlight: DRAFT → QUEUED → PRINTING → AWAITING_SHIPMENT; **CANCELED** covers cancelled and refunded orders; fulfillment examples also show SHIPPED / DELIVERED.
- `GET /orders` `limit` maximum **200** (docs; OpenAPI originally listed 100 — Studio resolves to 200 with `x-slant-studio-source: docs`).
- Fulfillment object (docs): `status`, `provider`, `deliveryMethod`, `address`, `trackingNumbers[]`, `deliveryInstructions`, `providerStatus`.
- `options.shippingProvider`: **SHIPPO** | **SHIPSTATION**.
- Metadata: at most **10** fields and depth **≤ 3**; no credentials; prefer camelCase.
- **Duplicate as New Draft** (guided Orders) is client-side only: it reads the order with `GET /orders/{publicOrderId}` and prefills the composer with each item's `type`, `publicFileServiceId` / `componentId` / `stationeryId`, `filamentId`, `quantity`, `name`, `SKU`, `imageUrl` (https only) and `options`, from the flat spec shape or the nested `printItem` / `componentItem` / `stationeryItem` shape. Items without a reference are listed as not copied. The shipping address and email are copied; an address country that isn't a recognised ISO code or country name stays unselected (never assumed to be US). `options.shippingProvider` and the platform are copied when valid; metadata and all prices are not. The new draft is created with the normal `POST /orders`, priced by Slant, and placed only through the existing charge review. Copied item `options` are shown per item in the composer and can be removed before the draft is created.
- Guided order details show, only when present: `items[].status` (`PROCESSING` | `READY` | `SHIPPED` | `DELIVERED`), `processedAt`, `options.shippingProvider` and `fulfillment.deliveryInstructions`. The bundled spec has no seller-settable order reference (no `orderNumber` field on `Order` or the `POST /orders` body), so Studio doesn't offer one; use `metadata` for your own references.
- Order costs (`printingCost`, `deliveryCost`, `totals.totalCost`) are documented in USD; `items[].currency` is documented as always USD. The guided list sorts **Created** by the parsed `createdAt` timestamp and **Total** by its decimal value, and defaults to the server `sortOrder` chosen in Filters.
- **Export Orders…** is client-side only: it writes the orders already loaded in the list to CSV without any request. Recipient/address columns are opt-in.
- Cancel (docs Cancel Order page): *“Currently cancelling an order will also refund it as well as cancel associated fulfillment. If already shipped then the order will only refund.”* A separate **Refund Order** docs section exists; **no refund endpoint is integrated** in OpenAPI or this app.

## Webhooks

- Headers: `X-Webhook-Timestamp` (**milliseconds**, comparable with `Date.now()`), `X-Webhook-Signature-256` (example `sha256=…`).
- Dead webhook **batch resend** (`POST …/webhook/resend`): capped at **25** per call. Response `data` fields (docs): `attempted`, `delivered`, `failed`, `expired`, `remaining`, `results[]`. Keep calling while `remaining` is above zero.
- **Single resend** (`POST …/webhook/{webhookId}/resend`) result fields (docs example): `id`, `eventType`, `success`, `status`, `expired`, `alreadyDelivered`, `error`.
- **Test webhook** (`POST …/webhook/dummy`): inspect `data.success` / `data.response.status`; `data.response.error` is present instead of status when the request failed outright (e.g. DNS failure or timeout).
- `webhookSecret` is **not settable on create** (auto-generated). Set your own via `PATCH /platforms/{platformId}` or regenerate with `PATCH …/webhook-secret`.
- **Signature recipe** (verbatim from docs SPA `verifyWebhookSignature` in `/tmp/slant-ux/docs.js`):

```javascript
function verifyWebhookSignature(payload, timestamp, signature, secret) {
  const expectedSignature = signature.replace('sha256=', '');
  
  // Reconstruct the signed payload (timestamp + body)
  const signedPayload = `${timestamp}.${payload}`;
  
  // Generate signature using your webhook secret
  const computedSignature = crypto
    .createHmac('sha256', secret)
    .update(signedPayload, 'utf8')
    .digest('hex');
  
  // Compare signatures securely
  const isValid = crypto.timingSafeEqual(
    Buffer.from(expectedSignature, 'hex'),
    Buffer.from(computedSignature, 'hex')
  );
  
  // Check timestamp freshness (reject if older than 5 minutes)
  const age = Date.now() - parseInt(timestamp);
  const isFresh = age < 5 * 60 * 1000;
  
  return isValid && isFresh;
}
```

Secret is the platform `webhookSecret` (trim before use; used exactly as submitted).

## Platforms, usage, health, OpenAPI

- `GET /platforms` returns **only enabled** platforms. Disabled platforms stay readable by ID via `GET /platforms/{platformId}` and can be re-enabled.
- `GET /usage` — account usage including per–API-key session usage (docs Check Usage). Not rate-limited the same way as mutation traffic; see live response envelope `success` / `message` / `data`.
- `GET /health/status` — public, no auth; cached ~2-minute micro-service health map under `data.{service}.healthy` / `lastCheckedAt` (docs Access / health).
- Official `GET https://slant3dapi.com/v2/api/openapi.json` returns the raw OpenAPI document (**not** wrapped in the usual `{success,message,data}` envelope). This app **bundles** the spec and does not fetch it at runtime.
- Customers / checkout endpoints appear in docs behind “not yet available” and are **intentionally excluded** from the catalog.

## Orders query params (docs)

- `startDate` / `endDate`: ISO 8601. Docs describe endDate as returning orders **up to that point**; file filters phrase endDate as “created **before this date**” (exclusive upper bound). Studio’s guided Orders filter sends the day after the chosen “To” date so the selected day is included.
- `sortOrder`: `ASC` | `DESC` (invalid sort/limit → 400 naming the parameter).
- Status filter includes the full enum listed above; a test checks the guided filter offers exactly the bundled `GET /orders` `status` enum.

## Catalog notes

- Components: `categoryId`, `price`, `priceUnit`, `dimensions`, `dimensionUnit`, `weight`, `tags`. Categories: `id`, `name`, `slug`, `parentId`.
- Filaments: optional boolean `available`.

## Doc vs spec conflicts (app resolves toward the **spec**)

| Topic | Docs | Spec / Studio |
| --- | --- | --- |
| Stationery image field | `imageURL` | `imageUrl` |
| Order platform placement | sometimes `customer.platformId` | top-level `platformId` |
| Address `state` | optional in site copy | required in Address schema |
| Orders batch body | `publicIds` | `public_ids` |
| Files batch body | bare array in JS example | `{ publicIds: [...] }` |
| Order list `limit` | max 200 | was 100 — Studio supplements to **200** |
| File `type` | stl, obj, 3mf | was stl-only — Studio supplements enums |

## Endpoint coverage (current app)

Guided = dedicated Models / Orders / Connection UI. Workbench = API Workbench. Unavailable = not callable with an API key (session/dashboard only) or not offered by the public API.

| Method | Path | Guided | Workbench | Unavailable | Notes |
| --- | --- | --- | --- | --- | --- |
| GET | `/files` | Models (cloud list) | Yes | | |
| POST | `/files` | Models (Import Model from URL…) | Yes | | type stl/obj/3mf; https links only |
| GET | `/files/owner/{ownerId}` | | Yes | | |
| GET | `/files/platform/{platformId}` | | Yes | | |
| GET | `/files/{publicFileId}` | Models (detail) | Yes | | |
| PATCH | `/files/{publicFileId}` | | Yes | | |
| DELETE | `/files/{publicFileId}` | Models (delete; falls back to hide) | Yes | | typed confirm. Spec-only (not in the human docs); 403 "Admin access required" for standard keys, even for the uploader |
| POST | `/files/direct-upload` | Models upload | Yes | | + confirm |
| POST | `/files/confirm-upload` | Models upload | Yes | | |
| POST | `/files/batch` | | Yes | | |
| POST | `/files/openScad` | | Yes | | STL bytes |
| POST | `/files/{publicFileId}/estimate` | Models estimate | Yes | | |
| GET | `/platforms` | Connection / browsers | Yes | | |
| POST | `/platforms` | Create platform | Yes | | |
| GET | `/platforms/{platformId}` | Platforms (re-enable by ID) | Yes | | |
| PATCH | `/platforms/{platformId}` | Platforms (edit) | Yes | | |
| DELETE | `/platforms/{platformId}` | Platforms (disable, with confirm sheet) | Yes | | Workbench: typed confirm |
| PATCH | `/platforms/{platformId}/webhook-secret` | Platforms (rotate secret) | Yes | | type `rotate` |
| PATCH | `/platforms/{platformId}/enable` | Platforms (re-enable) | Yes | | |
| POST | `/platforms/{platformId}/webhook/dummy` | Platforms (test webhook) | Yes | | |
| GET | `/platforms/{platformId}/webhook` | Platforms (failed deliveries) | Yes | | |
| POST | `/platforms/{platformId}/webhook/resend` | Platforms (resend failed deliveries) | Yes | | |
| POST | `/platforms/{platformId}/webhook/{webhookId}/resend` | Platforms (resend one delivery) | Yes | | |
| POST | `/slant/webhook` | | Yes | | custom server |
| GET | `/platforms/stripe/public-key` | | Yes | | |
| GET | `/orders` | Orders list | Yes | | limit ≤ 200 |
| POST | `/orders` | Order draft | Yes | | |
| GET | `/orders/{publicOrderId}` | Orders detail, review sheets, Duplicate as New Draft | Yes | | |
| POST | `/orders/{publicOrderId}` | Place order | Yes | | charge confirm |
| DELETE | `/orders/{publicOrderId}` | Cancel | Yes | | refund-aware copy |
| POST | `/orders/batch` | | Yes | | |
| GET | `/orders/search` | Orders search field (Return) | Yes | | falls back to `GET /orders?publicId=` on 404 |
| GET | `/components` | Catalog | Yes | | |
| GET | `/components/search` | | Yes | | |
| GET | `/components/categories` | Catalog (component categories) | Yes | | |
| GET | `/components/{id}` | | Yes | | |
| GET | `/filaments` | Materials | Yes | | `available` |
| GET | `/stationery` | Catalog | Yes | | |
| GET | `/usage` | Connection (Load Usage) | Yes | | |
| GET | `/apiKey` | | Link only | Session | Dashboard |
| POST | `/apiKey` | | Link only | Session | Dashboard |
| GET | `/health/status` | Connection (Check Service Status) | Yes | | Public |
| — | Refund order (docs only) | | | Yes | Not in OpenAPI |
| — | Customer create / checkout | | | Yes | Docs: not available |

Not yet guided (Workbench only): file metadata edits, owner/platform file lists, file and order batch lookups, OpenSCAD generation, Stripe public key, component search/detail and the custom webhook receiver. Possible later guided work: richer tracking, refunds UX if/when the API exposes it, and multi-format upload pickers in Models.
