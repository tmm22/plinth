# Slant 3D V2 API integration reference

Verified 18 October 2026 from [official documentation](https://slant3dapi.com/documentation/introduction) (docs SPA bundle `assets/index-DSzyXtco.js`), and [official OpenAPI](https://slant3dapi.com/v2/api/openapi.json). The bundled `Sources/SlantStudio/Resources/openapi.json` is the official spec plus doc-backed supplements marked with `x-slant-studio-source: docs`.

## Connection and prerequisites

- Production base: `https://slant3dapi.com/v2/api`. Bearer API key in `Authorization`, JSON bodies with `Content-Type: application/json`. Do not send bearer credentials to presigned storage URLs.
- Exception: `POST /slant/webhook` uses `https://slant3dapi.com/v2/slant/webhook`, outside the `/api` prefix (operation-specific server in OpenAPI).
- Rate limit: **100 requests/minute** per API key. Response headers: `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset` (epoch **milliseconds**, e.g. `1800000685873` = 60 s after the request, observed 23 Oct 2026; `rateLimitResetDate` also accepts epoch seconds, reads a small number as seconds from now, and ignores negative, unparseable or more-than-a-day-away values), `X-RateLimit-Role`. The public `/health/status` sends none of these, so Studio keeps the last known values whenever a response carries no rate-limit headers. OpenSCAD: **5 generations/hour**, one in flight. Up to three API keys and five enabled platforms. No public sandbox.
- Most workflows require an owned platform. Drafting does not charge; processing charges and starts production. Key creation/listing (`/apiKey`) is session-only (dashboard).

## Upload and manufacture

1. `POST /files/direct-upload` with `name`, `platformId` required; `ownerId` optional; `type` optional `stl` | `3mf` | `obj` (default `stl`). File records and `POST /files` use the same type set. The guided Models upload sends the library file unchanged in its original format, omitting `type` for STL and sending `obj` or `3mf` otherwise. OBJ/3MF preview, unit conversion and **Save STL copy** are local only; Slant never receives the converted copy unless you upload it as its own model. Slant does not document how it handles 3MF units other than millimetres or files that place several objects.
   - Local preview limits (client-side, `ModelFormats.swift` / `ZipArchive.swift`): 128 MB file and 500,000 triangles for every format. 3MF: at most 128 MB expanded in total, 10,000 ZIP entries, 1,000 model parts, component depth 32 and 100,000 placements (applied to both the triangle-count and the placement pass); entries over 1 MB that expand more than 200:1 are refused, as is any DTD (`<!DOCTYPE`/`<!ENTITY`, checked in UTF-8 and UTF-16 and by the XML parser's declaration callbacks). OBJ: lines up to 64 KB; polygons are ear-clipped on their best-fit plane (convex faces keep the fan from corner 0) within a per-file work budget; a face that crosses itself, or one over the budget, is previewed as a fan and blocks STL and scaled copies of that file.
2. PUT raw bytes to `data.presignedUrl` without Authorization; retain `data.filePlaceholder` unchanged.
3. `POST /files/confirm-upload` with `{ "filePlaceholder": <exact object> }`. Identifier is `publicFileServiceId`. Prefer `metrics` over deprecated `STLMetrics`.
4. Estimate with `POST /files/{publicFileId}/estimate`. Draft with `platformId`, customer details/address, and items.
   - Request: `{ "options": { "filamentId": <uuid>, "quantity": <int ≥ 1> } }`; both optional (PLA Black, quantity 1). Response `data`: `subtotal` (before surcharges), `total` (estimated print cost, USD), `pricePerUnit`, `quantity`, `totalMaterial`, `estimatedPrintTime`, `bodyChargeCost`, `oversizeSurcharge`. No delivery cost: shipping is priced only by the order draft (`totals.deliveryCost`). The OpenAPI gives no unit for `totalMaterial` or `estimatedPrintTime`, and live values disagree with the file's `metrics` (23 Oct 2026: `estimatedPrintTime` 6.66 against `printTimeEstimate` 402 minutes for the same 3MF; `subtotal` 7.64 against `pricePerUnit` 9.93 with both surcharges 0), so Studio shows the total, price per unit and any non-zero surcharge, and leaves print time and weight to Model analysis (`metrics`, documented as minutes and grams).
   - One material and one quantity per call; there is no batch estimate. Estimates are side-effect free and the only POST treated as a safe read (`isRetryableAPICall`); Studio still never retries them automatically, it only offers a manual Retry.
   - **Compare estimates** (`EstimateComparison.swift`; offered once the model is uploaded and materials are loaded) issues up to 20 of these calls (≤ 4 materials × ≤ 5 quantities), strictly sequentially and at least 0.6 s apart (100 requests/minute). Before each call it stops, keeping completed results, when `X-RateLimit-Remaining` ≤ 10 and `X-RateLimit-Reset` is in the future (without a reset header, a low count is trusted for 60 s), after a 429 (blocked until `X-RateLimit-Reset`, else numeric `Retry-After`, else 60 s), on 401/403/404/408/409/5xx or a transport error, after 3 consecutive per-cell failures (400/422 or a response without `total` or with a different `quantity`), or when the selected file, connection or global busy state changes. It does not set the app-wide busy flag. Rate-limit state is updated only from responses that carry `X-RateLimit-*` headers. Quantities are whole numbers from 1 to 10,000 (ambiguous input such as `1,500` is refused). Per unit is computed as `total ÷ quantity`; `total` is after surcharges (`subtotal` is before them), so surcharges are spread across the units. A cell applied with **Use** becomes the current estimate under the same `fileID|filamentID|quantity` context as **Get Estimate**.
   - **Check Cost** (Saved Products, `ProductCostCheck.swift`) sends the same request once per print line of a saved product, with `quantity` = the line's quantity × the units typed (once-per-order lines: the line's quantity alone) and the line's `filamentId`: at most 20 calls, with Compare estimates' spacing, rate-limit stop (≤ 10 remaining, or after a 429) and no retries, stopping after 3 prints in a row fail. It doesn't set the busy flag; it won't start while busy and stops before the next call if another task starts. Components and stationery are priced from the loaded catalog (`price` × quantity, USD only) without a request. Results are session-only; Activity records counts only.
5. Draft response `data` shape (docs): `{ order, items, totals: { printingCost, deliveryCost, totalCost }, customer }`.
6. Process with `POST /orders/{publicOrderId}`; cancel with `DELETE` (see refund note below). OpenSCAD returns raw STL bytes (`application/sla`).

## Delivery address defaults and lookup

The guided order composer defaults the shipping country from the Mac’s Region setting, with delivery details reused from the current session taking priority. Region is an editable default, not physical-location detection.

**Use Current Location** is an optional client-side Apple Core Location and reverse-geocoding flow, not a Slant endpoint. It requests permission only after the button is pressed and offers a suggested street address for review. **Use This Address** replaces shipping fields, clears the old apartment/unit number, and retains name and email. Coordinates are not added to the Slant order payload or activity log. The reviewed address is sent through the normal order-draft request when the user creates the draft.

The app rejects fixes older than 60 seconds or with horizontal uncertainty over 100 metres, and stops lookup after 45 seconds. These are app heuristics, not delivery-address verification. Missing street/country information, lookup errors and denied permission leave manual entry available. See `DeliveryLocation.swift` and the permission descriptions in `scripts/build-app.sh`.

## Orders, fulfillment, cancel / refund

- **Full status enum** (bundled schema): `DRAFT`, `PAID`, `QUEUED`, `PROCESSING`, `PRINTING`, `ITEMS_ON_SHELF`, `POST_PROCESSING`, `COMPLETED`, `IN_REVIEW`, `AWAITING_SHIPMENT`, `SHIPPED`, `DELIVERED`, `CANCELED`, `PAYMENT_ERROR`. Docs lifecycle highlight: DRAFT → QUEUED → PRINTING → AWAITING_SHIPMENT; **CANCELED** covers cancelled and refunded orders; fulfillment examples also show SHIPPED / DELIVERED.
- `GET /orders` `limit` maximum **200** (docs; OpenAPI originally listed 100 — Studio resolves to 200 with `x-slant-studio-source: docs`).
- Fulfillment object (docs): `status`, `provider`, `deliveryMethod`, `address`, `trackingNumbers[]`, `deliveryInstructions`, `providerStatus`.
- `options.shippingProvider`: **SHIPPO** | **SHIPSTATION**.
- Metadata: at most **10** fields and depth **≤ 3**; no credentials; prefer camelCase. Every draft Studio creates (composer, Import Orders) also carries `metadata.studioDraftId`, a fresh lower-case UUID per Create press or import job, added only when fewer than 10 fields are used and the seller hasn't typed that key (`DraftConfirmation.swift`). Observed 24 Oct 2026 (read-only): `GET /orders` list rows carry `createdAt`, `updatedAt` and `metadata` as a flat object or `null`.
- Order item `price` is the **line total**, not the unit price (observed 23 Oct 2026: quantity 2 → `price` 19.86, equal to `printingCost`, for a print estimated at 9.93 each).
- **Duplicate as New Draft** (guided Orders) is client-side only: it reads the order with `GET /orders/{publicOrderId}` and prefills the composer with each item's `type`, `publicFileServiceId` / `componentId` / `stationeryId`, `filamentId`, `quantity`, `name`, `SKU`, `imageUrl` (https only) and `options`, from the flat spec shape or the nested `printItem` / `componentItem` / `stationeryItem` shape. Items without a reference are listed as not copied. The shipping address and email are copied; an address country that isn't a recognised ISO code or country name stays unselected (never assumed to be US). `options.shippingProvider` and the platform are copied when valid; metadata and all prices are not. The new draft is created with the normal `POST /orders`, priced by Slant, and placed only through the existing charge review. Copied item `options` are shown per item in the composer and can be removed before the draft is created.
- Guided order details show, only when present: `items[].status` (`PROCESSING` | `READY` | `SHIPPED` | `DELIVERED`; only when the items' statuses differ), `processedAt`, `options.shippingProvider` and `fulfillment.deliveryInstructions`. The bundled spec has no seller-settable order reference (no `orderNumber` field on `Order` or the `POST /orders` body), so Studio doesn't offer one; use `metadata` for your own references. The bundled `Order` schema doesn't list `metadata` in responses; when an order does come back with `metadata.sourceOrderId` (optionally `metadata.source`), the details show it as the marketplace order with a Copy button. Absent metadata shows nothing.
- **Profit check** (order details) is client-side only and makes no requests: it reads the order's `total` / `totalCost`, or `printingCost` + `deliveryCost` (USD strings or numbers; a partial cost or a non-USD `currency` shows a reason instead), subtracts user-entered marketplace fees from what the buyer paid, and never sends or stores the amounts. For drafts Import Orders created this session, what the buyer paid (USD only, from the CSV's or Shopify's sale amounts, never taxes) is prefilled from memory, keyed by Slant order ID; those amounts are never sent to Slant.
- `POST /orders` (Create Draft) is not retried. An unknown outcome (timeout, transport error, 5xx, 408/409, a reply without an order id) makes the next Create Draft in any composer ask for **Create Anyway** until a creation is confirmed. The composer lists the newest 5 such attempts; an older one dropping off sets a flag that keeps the guard until a confirmed creation.
- **Look for Draft on Slant** (`DraftConfirmation.swift`) checks unconfirmed creates read-only: first the loaded list, then `GET /orders?page=N&limit=100&sortBy=createdAt&sortOrder=DESC&platformId=<the attempt's platform>` for up to 3 pages per platform (no status filter, so the 300 newest orders of any status), inside `store.run`, never retried, stopping before the next page when `X-RateLimit-Remaining` ≤ 10 and the window hasn't reset. A row whose `metadata.studioDraftId` matches confirms that attempt (owner decision: a found marker is proof of creation) and, for Import Orders, records it as created. Not finding a draft never clears anything: list rows may lack metadata, and the draft may be older than the pages read. Attempts sent without a marker can't be looked for.
- Order costs (`printingCost`, `deliveryCost`, `totals.totalCost`) are documented in USD; `items[].currency` is documented as always USD. The guided list sorts **Created** by the parsed `createdAt` timestamp and **Total** by its decimal value, and defaults to the server `sortOrder` chosen in Filters. The toolbar’s Status menu sends the `status` filter at once, keeping the dates and sort.
- **Export Orders…** (File menu) is client-side only: it writes the orders already loaded in the list to CSV without any request, and notes when `ordersHasMore` means older orders aren't loaded. Recipient, address and `metadata` (compact JSON, sorted keys) columns are one opt-in.
- **Import Orders…** (`OrderImport.swift`) creates order **drafts** from a CSV (Etsy Sold Order Items, Shopify orders export or Studio's template; ≤ 5 MB, ≤ 2,000 rows, ≤ 500 orders). Each draft is a normal `POST /orders` whose body is built only by `orderDraftPayload`, with the current platform and owner, items from saved products (`savedProductOrderLines`), and `metadata: { "source": "etsy" | "shopify" | "csv", "sourceOrderId": "<marketplace order ID>", "studioDraftId": "<uuid>" }`. Shopify orders (CSV or **Fetch from Shopify**) add `sourceItems`, and fetched orders add `sourceShop` (the store's `*.myshopify.com` address), so at most 5 of the 10 fields; see the Shopify section. The sale-amount columns are read for the Profit check only and never sent. Requests are strictly sequential, at least 1 s apart, and wait (cancellably, up to 5 minutes) for `X-RateLimit-Reset` when `X-RateLimit-Remaining` ≤ 10 (a full minute when no usable reset time came back) or after a 429. Outcomes follow `orderMutationErrorProvesNoEffect`: a 4xx other than 408/409 (including 429) or a failure before sending is **refused** and the batch continues (stopping on 401/403 or after 5 refusals in a row); a timeout, transport error, 5xx, 408/409, or a 2xx without an order ID is **unknown** and stops the batch. Nothing is retried and nothing is paid. The app-wide busy flag is held for the batch, and one `GET /orders` reload follows it. Duplicate checks use an in-memory session ledger plus loaded orders' `metadata.sourceOrderId`; `GET /orders` was seen returning `metadata` on 23 Oct 2026, but only for orders in the loaded list, so the ledger is still the dependable check within a session. The batch also stops if the key or platform changes. The unknown-outcome lock (pay/cancel, keyed by order ID) is not involved.
  - **Personalise with OpenSCAD** (`BatchPersonalise.swift`): for an order whose saved product links a print item to a `.scad` template, Studio first makes every model of that order with OpenSCAD on this Mac (never `POST /files/openScad`), checks each STL (readable, closed, within the upload size limit), then uploads each one with the normal `POST /files/direct-upload` → PUT → `POST /files/confirm-upload`, paced with the drafts (each upload counts as one paced request), and only then sends the draft with those `publicFileServiceId`s. Upload names are `Etsy order <digits> personalised` / `Shopify order <#digits> personalised` (" i of n" for several), or `Personalised model` for anything else, never the buyer's text. At most 20 models and 256 MB per order. An upload whose outcome is unknown (timeout, transport error, 5xx, 408/409, unreadable reply or a confirm without a file ID) stops the batch with that order's draft unsent; a refused upload skips that order. Nothing is retried, and the models aren't added to the library.
- **Pay Several Drafts…** (`BatchPay.swift`) uses only the single-order requests. Review: one `GET /orders/{publicOrderId}` per ticked draft (≤ 20), at least 0.6 s apart, inside `store.run`, with Import Orders' rate-limit wait (`orderImportPacing`: wait for the reset at ≤ 10 remaining or after a 429, stop rather than wait over 5 minutes); a 401/403 or a changed key/platform ends loading. Paying holds `busy` and, at least 1 s apart per order, sends `GET /orders/{id}` (re-check with `orderConfirmRecheck`, still DRAFT), records the unknown-outcome lock, then `POST /orders/{id}` and a best-effort `GET /orders/{id}`. After a 2xx the batch continues only when the returned order's status is placed (not empty, DRAFT, PAYMENT_ERROR or CANCELED); a 2xx that still shows DRAFT or no readable status keeps the lock and stops. A definite 4xx refusal (not 408/409) lifts that order's lock and stops the batch; anything else is unknown and stops it. Nothing is retried, nothing starts while any order's outcome is unknown, and the count, total, key and platform must match what was confirmed. Drafts are matched to marketplace orders by `metadata.source` + `sourceOrderId` + `sourceShop` + `sourceItems`: a second draft with the same key, or one whose key belongs to a placed order in the loaded list, is left out.
- **Spending Report** (`SpendReport.swift`) reads loaded orders only, except **Load the Whole Period**: read-only `GET /orders?page=N&limit=100&sortBy=createdAt&sortOrder=ASC&startDate=<start − 1 day>&endDate=<end + 1 day>` (dates as `yyyy-MM-dd` in the Mac's time zone, plus `platformId` when a default platform is set), then trimmed locally to orders created in the period on the Mac's calendar. At most 50 pages (5,000 orders), 0.6 s apart, inside `store.run`, stopping (keeping what loaded, with Continue Loading) at ≤ 10 remaining, after a 429, on an unreadable page or when the default platform changes. The orders stay in the sheet and never replace the Orders list. Printing cost per product uses only USD orders whose item `price`s (line totals), rounded to cents, add up to `printingCost`; delivery per country uses `deliveryCost` and the address country.
- Cancel (docs Cancel Order page): *“Currently cancelling an order will also refund it as well as cancel associated fulfillment. If already shipped then the order will only refund.”* A separate **Refund Order** docs section exists; **no refund endpoint is integrated** in OpenAPI or this app. `DELETE` on a `DRAFT` is refused with a 4xx whose message is “Can not cancel a draft order” (seen 23 Oct 2026), and no other endpoint removes a draft, so Studio offers no cancel for drafts (`orderCanRequestCancellation`) and the Workbench's guided DELETE check blocks it too. The pay/cancel review quotes Slant's message for a 400/422 refusal.

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

- Order watch makes at most two reads every 4 minutes and reads only the order-level `status` (and `updatedAt` for the sort check): `GET /orders?page=1&limit=100&sortBy=createdAt&sortOrder=DESC&platformId=…`, then, unless the first failed or the skip rules now apply (busy, modal UI, backoff, ≤ 20 remaining), `GET /orders?page=1&limit=100&sortBy=updatedAt&sortOrder=DESC&platformId=…`, so older orders that changed are seen too. Observed 24 Oct 2026 (read-only): `sortBy=updatedAt&sortOrder=DESC` → 200, newest update first (`ASC` reverses it). The second read is turned off for the rest of the session after a 400/422 or a reply whose readable `updatedAt` values aren't in descending order (more than 1 s out). The two are merged by ID (the second wins); the merge goes only into `order-watch.json`. The banner's **Show** reloads page 1 and then reads up to 10 changed orders that weren't on it with `GET /orders/{publicOrderId}`, one at a time inside `store.run`, adding those on the current platform to the list (a 404 is skipped; any other error stops the reads). A notification click does the same for its one order; the notification's `userInfo` holds only `orderID`. Its rate-limit figures replace Studio's only when they aren't older (a later `X-RateLimit-Reset`, or the same window with the same or lower `X-RateLimit-Remaining`), because its reply can arrive after a newer one to the seller's own request.
- Items (seen 23 Oct 2026 on a DRAFT): both the item and `printItem` carry `estimatedPrintCompletion` (null), `printItem.assignments` is an empty array, and the item `status` is PROCESSING, so item status isn't production progress. Docs describe assignments with a status (QUEUED/PRINTING/ON_SHELF), `krakenStatus` and printer details; Studio reads assignment `status` only (shape unverified until a paid order is seen). `fulfillment` is null on drafts; `fulfillment.address` is compared with the shipping address for display only, and `fulfillment.provider` may be the label service (Shippo, ShipStation) rather than the carrier. Not yet confirmed: whether list rows include `fulfillment` and whether `arriveByDate` is filled in.
- `POST /orders/batch` takes `{"publicIds": [...]}` and returns `data: [orders]` (seen 23 Oct 2026); the spec's `public_ids` is refused with 400 “No public IDs provided”. Studio doesn't use it yet.
- No Slant support address is documented; the OpenAPI `info.contact` is the API developer contact, so Report a Problem only copies its message.
- Stationery (spec): nullable `price` and `weight`, a `dimensions` string, an integer `quantity` (meaning undocumented) and `available`, with no unit fields. Studio shows units only if Slant sends `priceUnit`, `dimensionUnit` or `weightUnit` (unverified). Components send `weight` with `weightUnit`.
- `POST /files/openScad` (Personalise from Template): the body is `{ scadCode }`, holding the template with the values appended as assignments; the reply is STL bytes. Studio counts 5 an hour per session, one at a time, counts every request sent whatever the outcome, and never retries. After a 429 it waits for a numeric `Retry-After`, else a future `X-RateLimit-Reset` (each capped at 1 h), else 1 h. Templates with `include`/`use` aren't sent. Design an Accessory never uses it: Claude's code passes `scadSafetyProblem` and is rendered only by OpenSCAD on the Mac (120 s, `openSCADMemoryLimitBytes`). Observed 23 Oct 2026: a small template using `text()` and `linear_extrude` returned a closed STL of the expected size in a few seconds, so Slant's default font works. Unverified: Slant's fonts and libraries, whether failed generations count, and which headers its 429 carries.
- The live OpenAPI at `https://slant3dapi.com/v2/api/openapi.json` no longer lists `POST /files` (upload by URL, used by **Upload from URL…**), though the docs still describe it (checked 23 Oct 2026). Keep the feature, but expect it may be withdrawn.
- `GET /orders/search` is answered like `GET /orders/{publicOrderId}` with the ID `search`: every query, even an exact order number, returns 400 “Order not found.” (seen 23 Oct 2026; `GET /orders/xyz` gives the same reply). `search` and `q` parameters on `GET /orders` are ignored. Studio therefore falls back to `GET /orders?publicId=` (upper-cased, `SLANT_` added to a bare number), which matches exact order numbers only, and the search hint promises only that.
- `startDate` / `endDate`: ISO 8601. Docs describe endDate as returning orders **up to that point**; file filters phrase endDate as “created **before this date**” (exclusive upper bound). Studio’s guided Orders filter sends the day after the chosen “To” date so the selected day is included.
- `sortOrder`: `ASC` | `DESC` (invalid sort/limit → 400 naming the parameter).
- Status filter includes the full enum listed above; a test checks the guided filter offers exactly the bundled `GET /orders` `status` enum.

## Shopify (optional, seller's own store)

Not a Slant API: Studio talks to the seller's store directly (`ShopifyClient.swift`, `ShopifyImport.swift`, `ShopifyTracking.swift`, `ShopifyOrderMatching.swift`). Requests go only to `https://<handle>.myshopify.com`; custom domains are refused, input is normalised to `handle.myshopify.com` (bare handle, `handle.myshopify.com` or `admin.shopify.com/store/handle`), and redirects are refused.

- **Auth:** a Dev Dashboard app's client ID and secret, exchanged with `POST https://<shop>/admin/oauth/access_token` (form body `grant_type=client_credentials&client_id=…&client_secret=…`); the token is kept in memory only, for `expires_in` (86,400 s if absent, clamped to 60 s–48 h, renewed 60 s early; a read that gets a 401 fetches a new token once, and a mutation renews a token with under 5 minutes left). Or a legacy `shpat_` Admin API token from a custom app made in the store admin, sent as `X-Shopify-Access-Token`. Credentials are in the Keychain (service `SlantStudio`, account `shopify-credentials`, this device only); the shop address is in preferences (`shopifyShopDomain`). Scopes: `read_orders` (or `write_orders`) to import; `write_merchant_managed_fulfillment_orders` (or the assigned/third-party fulfilment-order write scopes) to send tracking, read from the token reply's `scope` or `currentAppInstallation.accessScopes`.
- **Endpoint:** Admin GraphQL `POST https://<shop>/admin/api/2026-10/graphql.json`. Operations by name: queries `StudioShop` (Test Connection: shop name, `myshopifyDomain`, `plan { publicDisplayName partnerDevelopment }`, scopes), `StudioScopes`, `StudioImportOrders`, `StudioFindOrder`, `StudioFulfilmentCheck`; mutation `StudioSendTracking` (`fulfillmentCreate`). 30 s request timeout, replies capped at 4 MB, ephemeral session. Any top-level GraphQL error fails the request.
- **Throttling:** Studio tracks `extensions.cost.throttleStatus` and waits before a request when the bucket is short. HTTP 429 or the `THROTTLED` code is throttled (`Retry-After` honoured, capped at 30 s); reads are retried at most 3 times, each wait ≤ 30 s. Mutations are sent once and never retried (`fulfillmentCreate` has no idempotency key).
- **Fetch from Shopify** (Import Orders): `StudioImportOrders` with `query: "financial_status:paid fulfillment_status:unfulfilled status:open created_at:>=<60 days ago, UTC>"`, oldest first, 8 orders per page (estimated cost 620), at most 250 orders and 30 line items each (an order with more is left out, to import from CSV). Any early stop fails the whole fetch rather than showing a partial list. Read: order `name` (the `sourceOrderId`, such as `#1001`), email, cancellation and statuses, the shipping address (no phone), line items (`id`, `name`, `sku`, `currentQuantity`, visible `customAttributes` as personalisation) and `shopMoney` sale amounts. The result goes into the unchanged import sheet; nothing is sent to Slant until the seller confirms.
- **Draft metadata:** `sourceShop` (fetched orders) and `sourceItems`, compact JSON such as `[{"lineItem":"123","quantity":2}]` with each entry keyed by the line item's numeric ID, else its SKU (never its name, which can carry a buyer's text); written only when every included item has one, with at most 60 entries and 1,000 characters (read back up to 2,000).
- **Send Tracking to Shopify…:** for imported Shopify orders with Slant tracking (≤ 50). A read-only check first (`StudioFindOrder` by exact `name`, then `StudioFulfilmentCheck`: cancellation, existing fulfilments and tracking numbers, one fulfilment order with `CREATE_FULFILLMENT` and ≤ 30 lines). A draft whose `sourceShop` is another store is refused without contacting Shopify; one without `sourceShop` (a CSV import) must match the order's shipping name and postcode and is never ticked automatically. Only the units recorded in `sourceItems` are allocated; too few unfulfilled units blocks the order. Each send re-runs the check, then `fulfillmentCreate` with exactly those fulfilment-order line items, `trackingInfo` (number(s) and company) and `notifyCustomer` (off by default), one order at a time, 0.5 s apart. The first unknown outcome (408/409, 3xx, 5xx, transport error, unreadable reply, cancelled in flight) stops the run; 3 refusals in a row also stop it.
- **Unverified:** live query costs (Studio uses its own estimates), the status code Shopify uses for throttling in practice (429 and `THROTTLED` are both handled), whether scope approval and protected customer data access need extra review for a Dev Dashboard app, how Basic/Starter plans withhold customer names and addresses from custom apps (Studio warns when the plan name contains "basic" or "starter" and treats "not approved to access" errors as withheld data), and whether Slant keeps a 1,000-character `sourceItems` string intact (Slant documents no metadata value length).

## Design tools (optional, seller's own keys)

Not Slant APIs. Design an Accessory, Generate a Replica and Review for Printing call Anthropic, Meshy or Tripo with the seller's own keys, from Keychain service `SlantStudio`, accounts `anthropic-api-key`, `meshy-api-key` and `tripo-api-key` (this device only). Each key goes only to its own API host (`api.anthropic.com`, `api.meshy.ai`, `openapi.tripo3d.ai` or `openapi.tripo3d.com`) and is redacted from errors and Activity (`aiServiceRedacted`, `imageTo3DRedacted`). Photos are prepared by `ImagePreparation.swift` before sending: read by content (JPEG, PNG or HEIC, ≤ 30 MB, ≤ 120 megapixels), turned upright, long edge ≤ 1568 px for Claude or ≤ 2048 px for Meshy/Tripo, and re-encoded as JPEG (≤ 3.75 MB) without EXIF, GPS, XMP or comment segments. Nothing these tools make reaches Slant until the seller uploads a saved copy. **Nothing in this section has been tested live**; the request shapes come from each provider's documentation (read 24 Oct 2026).

### Anthropic Messages

- **Request** (`AnthropicClient.swift`): `POST https://api.anthropic.com/v1/messages`, headers `x-api-key`, `anthropic-version: 2023-06-01`, `anthropic-beta: server-side-fallback-2026-07-01` (the client can add `thinking-display-updates-2026-08-18`, but no caller asks for it), `content-type: application/json` and `accept: text/event-stream`. Body: `model: "claude-opus-5-5"`, `max_tokens`, `stream: true`, a top-level `system` array, `tools` (every one `strict: true`), `tool_choice: {"type": "auto"}` with `disable_parallel_tool_use: true` where tools are sent, `thinking: {"type": "adaptive"}`, `output_config.effort`, `fallbacks: "default"`, optional top-level `cache_control`, then `messages`. Images (base64 `image/jpeg`; `image/png` is also accepted by the builder) come before the text in the first user turn.
  - Design an Accessory: `max_tokens` 48,000, effort `high`, tools `render_scad`, `ask_seller` and `finish_design` (with `eager_input_streaming: true`), 2 cache breakpoints (5-minute `ephemeral` on the system block, plus top-level automatic caching).
  - Review for Printing: `max_tokens` 32,000, effort `high` (the one follow-up `medium`), the single tool `propose_plan` (`eager_input_streaming: false`, nullable fields as `anyOf` with `null`), 1 cache breakpoint (5-minute `ephemeral` on the system block, which also covers the tool before it).
  - Save & Test: `max_tokens` 256, effort `low`, no tools or system prompt, the text “Reply with the single word OK.”
  - At most 4 cache breakpoints (checked before sending); the 1-hour TTL is supported but unused.
- **Transport:** ephemeral session (no cookies, cache or credential storage), redirects refused, 300 s idle and 3,600 s total timeout, request body and streamed reply each ≤ 32 MiB, error bodies ≤ 256 KiB. Never retried. The only automatic extra requests are Review for Printing's one follow-up (when the reply has no usable `propose_plan` call) and Design an Accessory's one nudge (when Claude answers without a tool call); **Try Again** in the accessory sheet is an explicit, billed resend.
- **Replies:** history keeps a reply (`.assistant(message)`) only when `canJoinHistory`: `stop_reason` `end_turn`, `tool_use`, `stop_sequence` or `pause_turn`. A `refusal` discards everything written and quotes `stop_details.explanation` (≤ 400 characters); `max_tokens`, `model_context_window_exceeded` and other early stops can't join history. Tools run only on `tool_use`, and a call whose input fails Studio's checks is answered with an error result, never run. Studio reads `fallback` content blocks (`from.model`, `to.model`), `usage.iterations[]` (per-iteration `type`, `model` and tokens, including the 5m/1h `cache_creation` split) and `stop_details`; after a mid-reply switch, only the text before the switch joins history.
- **Price** (`anthropicEstimatedCost`, per million tokens): Claude Opus 5.5 $4 input, $20 output, $0.20 cache read, $5 cache write (5 minutes) and $8 (1 hour); each `usage.iterations` entry is priced at its own model's rate (Opus 5 and Opus 4.8 at $5/$25/$0.50/$6.25/$10). Usage Studio can't price shows as “at least $X”.
- **Forecasts** (shown before sending; Anthropic's invoice is what counts): Design an Accessory assumes about 3.5 characters per token, one image token per 750 pixels, 8,000 output tokens and 4,000 history tokens per reply, and 4 renders of 512 px per later reply, all input written to the 5-minute cache and read back; it shows a typical design (5 replies) and the maximum (10). Review for Printing assumes about 3 characters per token, 784 tokens per 768 px picture (28 px patches), and 3,000–16,000 output tokens, with the high end adding the one follow-up (8,000 output).
- **Unverified:** the streamed shapes of `stop_details`, `usage.iterations` and `fallback`; whether strict tools with `eager_input_streaming` are accepted; whether the `propose_plan` schema's `anyOf` nullable fields are accepted under `strict`; the context-window stop reason's name (`model_context_window_exceeded`); and the cost forecasts' token assumptions.

### Meshy

`MeshyClient.swift`. Base `https://api.meshy.ai/openapi`, header `Authorization: Bearer msy_…`, JSON bodies, 30 s (GET) / 60 s (POST) timeouts. Every create answers 202 `{"result": "<task id>"}` and is sent once (Meshy has no idempotency key; a 4xx means no task was created).

- **Image to 3D:** `POST /openapi/v1/image-to-3d` with `image_url` (a `data:` URI, ≤ 20 MB), `ai_model: "meshy-7.1"` (pinned), `should_texture: false`, `should_remesh: true`, `topology: "triangle"`, `target_polycount` (clamped to 100–300,000; Studio asks for 150,000 for a display piece and 20,000 for a functional part) and `target_formats: ["stl"]` (or `"3mf"`); Generate a Replica also sends `auto_size: true` and `origin_at: "bottom"`. Read with `GET /openapi/v1/image-to-3d/{id}` (`status` PENDING, IN_PROGRESS, SUCCEEDED, FAILED, CANCELED, EXPIRED; `progress`; `model_urls`; `task_error`, with `moderation_blocked` reported as refused content). About 20 credits (mesh only); a failed task is refunded.
- **Analyze Printability (free):** `POST /openapi/v1/print/analyze` with `input_task_id`, plus `printer_type: "fdm"` and `intended_print_longest_side_mm` (the replica's processed longest side, 0.1 mm) when known; read with `GET /openapi/v1/print/analyze/{id}` (`printability.status`, error and warning counts, watertight/holes/non-manifold/degenerate metrics, thin walls).
- **Repair Printability (about 10 credits) then Convert (1 credit):** `POST /openapi/v1/print/repair` (same body), then `POST /openapi/v1/convert` with `target_formats` and `input_task_id`; only after a 400/422 refusal does Studio resend Convert once with the repair's own GLB link as `model_url`. Implemented (`runMeshyRepair`), but no screen uses it yet.
- **Balance:** `GET /openapi/v1/balance` → `balance` (Save & Test and Check Balance).
- **Errors:** 402 = not enough credits or the Free plan (which has no API access); 429 = rate or concurrency limit, with `Retry-After` on the rate limit. Running tasks' `Retry-After` is used as the poll interval (2–30 s). Generated files stay on `assets.meshy.ai` for 3 days.
- **Unverified:** whether Convert accepts a repair task's ID; the STL's units and up axis (Studio always rescales to the typed size and offers As Made / Turned Upright); whether about 150,000 triangles is honoured; the API's test key.

### Tripo3D

`TripoClient.swift`. Tripo's v3 API on one of two regional sites with separate keys: `https://openapi.tripo3d.ai/v3` (international) or `https://openapi.tripo3d.com/v3` (China mainland). Header `Authorization: Bearer <key>`; replies are `{"code": 0, "data": {…}}`, and any other code is an error.

- **Upload:** `POST /v3/files`, multipart with the single field `file` (JPEG or PNG, ≤ 20 MB) → `data.file_token`. Free; any failure counts as not sent.
- **Generation:** `POST /v3/generation/image-to-model` with `input` (the file token), `model: "v3.1-20260211"` (pinned), `texture: false`, `pbr: false` and `face_limit` (clamped to 500–1,500,000; 150,000 or 20,000 by purpose) → `data.task_id`. GLB only; 20 credits.
- **Tasks:** `GET /v3/tasks/{id}` (`status` queued, running, success, failed, banned, expired, cancelled; `progress`; `output.model_url`).
- **Convert:** `POST /v3/models/convert` with `input` (the generation task) and `format: "STL"` (or `"3MF"`), 5 credits. The client adds `pivot_to_center_bottom: true` only when asked for the origin at the bottom, which makes it a 10-credit conversion; Generate a Replica never asks (Studio places the model itself), so a replica costs about 25 credits.
- **Balance:** `GET /v3/account/balance` → `data.balance`, `data.frozen`.
- **Errors:** Tripo's `code` is read only on a 2xx or a 4xx other than 408/409; otherwise the HTTP status decides, so an unclear create stays unknown. HTTP 429, code 1007 (rate) or 2000 (concurrency, with `Retry-After`) is rate-limited; 2010 is not enough credits; 1000/1001 are treated as a bad key; a readable 2xx refusal is a refusal.
- **Conversion links:** an `output` link is kept only if it passes the download checks; an STL/3MF extension is preferred, but a link with any other or no extension is accepted and its content decides (ZIP → 3MF, glTF refused, else parsed as STL).
- **Unverified:** the download host; whether `model_url` links expire after about 5 minutes; `face_limit` above 20,000; the link format.

### Polling and unknown outcomes

`ImageTo3D.swift`. Status reads every 4 s, up to 10 minutes per stage; transient failures (transport, 408, 5xx, unreadable reply) back off as start × 2^n, capped at 60 s, and 5 in a row stop the run. A 429 waits for `Retry-After` (seconds or HTTP date, capped at 120 s; 16 s without one) and doesn't count as a failure. The API session never follows redirects (a 3xx is unknown) and caps JSON replies at 2 MB. A create whose outcome is unknown (408, 409, 3xx, 5xx, transport error, unreadable or oversized reply, cancelled in flight) is recorded in `ImageTo3DConnection.unconfirmedRequests` (memory only, ≤ 10 with an overflow flag, kept through key and service changes until quit); any other 4xx (including 402 and 429) means not sent. A stop after a task exists keeps a resume point (task and conversion IDs), so **Keep Waiting** polls or downloads the same task without a new create.

### Downloads

Generated models are downloaded (`imageTo3DDownloadURLProblem`) only over https, from a named host that isn't `localhost`, `*.local` or `*.localhost` or an IP literal (checked by name; DNS isn't resolved), with no user, password or fragment. Size ≤ 128 MB, checked against `Content-Length` and while reading; empty bodies refused; 15-minute timeout; 403/404 reported as expired. The download session is ephemeral, sends no `Authorization` header or cookies, and checks every redirect against the same rules. Files land in a `SlantStudio-Generated3D-<UUID>` temporary folder that is removed after processing.

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

Guided = dedicated Models / Orders / Catalog / Settings UI (platforms are managed in Settings › Account; usage and service status in Settings › Advanced). Workbench = API Workbench. Unavailable = not callable with an API key (session/dashboard only) or not offered by the public API.

| Method | Path | Guided | Workbench | Unavailable | Notes |
| --- | --- | --- | --- | --- | --- |
| GET | `/files` | Models (cloud list) | Yes | | |
| POST | `/files` | Models (Upload from URL…) | Yes | | type stl/obj/3mf; https links only |
| GET | `/files/owner/{ownerId}` | | Yes | | |
| GET | `/files/platform/{platformId}` | | Yes | | |
| GET | `/files/{publicFileId}` | Models (detail) | Yes | | |
| PATCH | `/files/{publicFileId}` | | Yes | | |
| DELETE | `/files/{publicFileId}` | Models (delete; falls back to hide) | Yes | | typed confirm. Spec-only (not in the human docs); 403 "Admin access required" for standard keys, even for the uploader |
| POST | `/files/direct-upload` | Models upload, Import Orders (personalised models) | Yes | | + confirm |
| POST | `/files/confirm-upload` | Models upload, Import Orders (personalised models) | Yes | | |
| POST | `/files/batch` | | Yes | | |
| POST | `/files/openScad` | Personalise from Template (Slant engine) | Yes | | STL bytes; 5/hour, never retried |
| POST | `/files/{publicFileId}/estimate` | Models estimate, Compare estimates, Saved Products (Check Cost) | Yes | | one material/quantity per call; sequential comparison or cost check ≤ 20 calls |
| GET | `/platforms` | Settings › Account | Yes | | |
| POST | `/platforms` | Create platform | Yes | | |
| GET | `/platforms/{platformId}` | Settings › Account platforms (re-enable by ID) | Yes | | |
| PATCH | `/platforms/{platformId}` | Settings › Account platforms (edit) | Yes | | |
| DELETE | `/platforms/{platformId}` | Settings › Account platforms (disable, with confirm sheet) | Yes | | Workbench: typed confirm |
| PATCH | `/platforms/{platformId}/webhook-secret` | Settings › Account platforms (rotate secret) | Yes | | type `rotate` |
| PATCH | `/platforms/{platformId}/enable` | Settings › Account platforms (re-enable) | Yes | | |
| POST | `/platforms/{platformId}/webhook/dummy` | Settings › Account platforms (test webhook) | Yes | | |
| GET | `/platforms/{platformId}/webhook` | Settings › Account platforms (failed deliveries) | Yes | | |
| POST | `/platforms/{platformId}/webhook/resend` | Settings › Account platforms (resend failed deliveries) | Yes | | |
| POST | `/platforms/{platformId}/webhook/{webhookId}/resend` | Settings › Account platforms (resend one delivery) | Yes | | |
| POST | `/slant/webhook` | | Yes | | custom server |
| GET | `/platforms/stripe/public-key` | | Yes | | |
| GET | `/orders` | Orders list, order watch, Look for Draft on Slant, Spending Report (Load the Whole Period) | Yes | | limit ≤ 200 |
| POST | `/orders` | Order draft, Import Orders | Yes | | never retried |
| GET | `/orders/{publicOrderId}` | Orders detail, review sheets, Duplicate as New Draft, Pay Several Drafts, order watch Show and notification clicks | Yes | | |
| POST | `/orders/{publicOrderId}` | Place order, Pay Several Drafts | Yes | | charge confirm |
| DELETE | `/orders/{publicOrderId}` | Cancel | Yes | | refund-aware copy |
| POST | `/orders/batch` | | Yes | | |
| GET | `/orders/search` | Orders search field (Return) | Yes | | falls back to `GET /orders?publicId=` on 404 or 400 “Order not found.” |
| GET | `/components` | Catalog | Yes | | |
| GET | `/components/search` | | Yes | | |
| GET | `/components/categories` | Catalog (component categories) | Yes | | |
| GET | `/components/{id}` | | Yes | | |
| GET | `/filaments` | Materials | Yes | | `available` |
| GET | `/stationery` | Catalog | Yes | | |
| GET | `/usage` | Settings › Advanced (Load Usage) | Yes | | |
| GET | `/apiKey` | | Link only | Session | Dashboard |
| POST | `/apiKey` | | Link only | Session | Dashboard |
| GET | `/health/status` | Settings › Advanced (Check Service Status) | Yes | | Public |
| — | Refund order (docs only) | | | Yes | Not in OpenAPI |
| — | Customer create / checkout | | | Yes | Docs: not available |

Not yet guided (Workbench only): file metadata edits, owner/platform file lists, file and order batch lookups, Stripe public key, component search/detail and the custom webhook receiver. Possible later guided work: richer tracking and refunds UX if/when the API exposes it. The Models import panel, drag and drop, Finder **Open With** and URL import already accept STL, OBJ and 3MF.
