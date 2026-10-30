# 3DAPI (dapi.digital) integration contract for Plinth

Researched 31 Oct 2026 (the API's clock read Fri 30 Oct 2026 21:42 UTC). Sources: `/tmp/dapi-docs/llms.txt`, `llms-full.txt`, `openapi.json` (OpenAPI 3.1.0, `info.version` 2.0.0), the deprecated v1 spec (`https://public-api.dapi.digital/docs/v1.openapi.json`, fetched keyless), keyless GETs to public endpoints, and www.dapi.digital pages.

**Tags:** **[docs]** = the guides and reference in `llms-full.txt` (page named). **[spec]** = `openapi.json` (path and method, or schema). **[live]** = a keyless GET I made on 30/31 Oct 2026. **[web]** = the www.dapi.digital marketing or help pages. **[inferred]** = my reading, not stated anywhere. **[unverified]** = needs a key or the owner's dashboard to confirm.

**Timing warning:** API v2, the integrator account type and these docs launched **30 Oct 2026**, the day before this research. Changelog v2.8.0: "a new version of the 3DAPI API … and a brand new user type - Integrators. … The previous API keeps working and is marked as deprecated" [web: /changelog]. Expect churn. The guides and the spec already disagree in places (§9).

---

## 0. Basics

| Item | Value | Source |
|---|---|---|
| Base URL | `https://public-api.dapi.digital` (only server in spec) | [spec `servers`] |
| Version prefix | `/v2` (designers and integrators); `/v1` is deprecated; `/v1/print-farm` is for farms | [docs Quickstart] |
| Auth header | `x-api-key: <key>`. The alternative is `Authorization: Bearer <dashboard session>`; sending both → 401 `ambiguous_credentials` | [spec `securitySchemes`], [docs Authentication] |
| Body format | JSON over HTTPS, snake_case fields, an `object` field on everything, ISO 8601 UTC times, `null` rather than missing fields | [docs Quickstart] |
| IDs | Opaque, with prefixes: `upl_`, `qte_`, `ord_`, `itm_`, `mat_`, `prd_`, `var_`, `dsg_`, `xtr_`, `apr_`, `evt_`, `req_`, `key_`, `itg_`, `rfd_` | [docs], [spec patterns e.g. `^upl_[0-9A-Za-z]+$`] |
| Money | `{ "amount": <int minor units>, "currency": "usd" }`, currency pattern `^[a-z]{3}$`. "Every amount is `usd` today" | [docs], [spec] |
| Lists | `{ "object":"list", "data":[…], "has_more":bool, "next_cursor":string\|null }`; query `limit` 1–100 (default 20), `cursor` | [docs Pagination], [spec] |
| Expand | `expand[]=<path>`, up to 3 levels. Without the needed read scope the reference stays as is (not an error) | [docs Expanding] |
| Request ID | Response header `request-id: req_…`; also in `details.request_id` on errors | [live], [docs FAQ] |
| CORS-exposed headers | `Idempotent-Replayed, Request-Id, X-RateLimit-Limit, X-RateLimit-Remaining, X-RateLimit-Reset, Retry-After`. `Idempotent-Replayed` appears in no doc or spec | [live] |
| http → https | `http://…/v2/health` → **307** `Location: https://…` | [live] |
| Trailing slash | `GET /v2/health/` → 200 | [live] |
| Redirects on API calls | Nothing documented. Plinth should refuse redirects, as it does for Slant | [inferred] |
| Sandbox | **None.** "Every request works on your real account" | [docs FAQ] |
| SDKs | None. Use the OpenAPI spec | [docs FAQ] |

---

## 1. Account types: designer (seller) and integrator

### 1.1 What each is for
- **Seller/designer account:** "if you sell your own products from a catalog: listings with variants, a 3DAPI storefront, orders from your other stores, stock and quality checks." [docs Quickstart]
- **Integrator account:** "if your app or website orders prints of files that change per order: generated models, or digital files with a 'buy it printed' button. You quote any file and order it, paid from your wallet or by your customer on a 3DAPI checkout." [docs Quickstart]
- "One email cannot hold both, and a seller account cannot be converted." [docs Quickstart, Business guide, FAQ] "An integrator account can never also be a seller account on 3DAPI." [docs Integrator onboarding `create_integrator_account`]
- Calling the other kind's endpoint → **403 `actor_not_allowed`**. `x-audience` on each operation says which kind it is for. [docs Authentication], [spec]
- Integrator keys are refused by `/v1` (apart from `/v1/me`). [docs Authentication]

### 1.2 Operations by audience [spec `x-audience`, `x-required-scopes`; any one scope listed is enough]

**Both kinds:**

| Method path | operationId | Scopes |
|---|---|---|
| GET `/v2/health` | get_health | none (public, not rate limited) |
| GET `/v2/me` | get_me | none (any valid key) |
| GET `/v2/shipping/rates` | get_shipping_rates | none (public) |
| GET `/v2/shipping/quote` | get_shipping_quote | none (public) |
| GET `/v2/materials`, `/v2/materials/{id}` | list_materials, get_material | none (public) |
| GET `/v2/categories`, `/v2/categories/{id}` | list_categories, get_category | none (public) |
| POST `/v2/uploads` | create_upload | `products:write` \| `extras:write` \| `stocks:write` \| `qc:write` \| `quotes:write`, but the purpose is restricted by account kind (§2.1) |
| GET/POST/PATCH `/v2/extras…` | list/create/get/update_extra | `extras:read` / `extras:write` |
| GET `/v2/wallet`, `/v2/transactions`, `/v2/transactions/summary` | get_wallet, list_transactions, get_transaction_summary | `wallet:read` |
| GET `/v2/events`, `/v2/events/{id}`, `/v2/webhook-endpoints` | list_events, get_event, list_webhook_endpoints | `webhooks:read` |

**Integrator only:**

| Method path | operationId | Scopes |
|---|---|---|
| POST `/v2/quotes` | create_quote | `quotes:write` |
| GET `/v2/quotes` | list_quotes | `quotes:read` |
| GET `/v2/quotes/{id}` | get_quote | `quotes:read` |
| GET `/v2/integrator/onboarding` | get_integrator_onboarding | `quotes:read` |
| POST/GET `/v2/integrator/approval-requests[/{id}]` | create/list/get_approval_request | `quotes:write` / `quotes:read` |
| POST `/v2/integrator/orders` | create_integrator_order | `orders:write` |
| GET `/v2/integrator/orders`, `/v2/integrator/orders/{id}` | list/get_integrator_order | `orders:read` |
| POST `/v2/integrator/orders/shipping-estimate` | estimate_integrator_order_shipping | `orders:read` |
| POST `/v2/integrator/orders/{id}/cancel` | cancel_integrator_order | `orders:write` |
| account, EU responsible person, API keys, billing, cards, top-ups, withdrawals, payout, webhook-endpoint writes, analytics, logs | various | `[]`, and most need a **dashboard session** (`credential_not_allowed` for keys) |
| POST `/v2/integrator/accounts`, `/v2/integrator/accounts/confirmation` | sign-up, resend | public |

**Designer only:** products, variants, designs, compliance, `create_order` / `list_orders` / `get_order` / `cancel_order` (`/v2/orders…`), import issues, QC tickets, stocks, stock batches, stock purchases, regions, attachments.

### 1.3 Scopes [docs Authentication], [spec `get_me` enum]
`products:read|write`, `orders:read|write`, `orders:read_customer`, `stocks:read|write`, `extras:read|write`, `qc:read|write`, `wallet:read`, `webhooks:read`, `quotes:read|write`. Legacy key permissions: `full` (everything), `order` (= `orders:read` + `orders:write`), and `pricing`, which "has none in this API". A request outside the key's scopes → 403 `missing_scope`.
- Integrator keys may carry only: `quotes:read`, `quotes:write`, `orders:read`, `orders:write`, `orders:read_customer`, `extras:read`, `extras:write`, `wallet:read`, `webhooks:read` (`scope_not_allowed` otherwise). Up to 10 active keys. Keys "work before your account is approved, with the same onboarding limits". [docs API keys `create_api_key`]
- Without `orders:read_customer`, orders show only the shipping country; customer, address and notes are null. [docs Authentication]

### 1.4 Integrator restrictions (all [docs] unless marked)
- **Sign-up** at dapi.digital/integrator/sign-up or POST `/v2/integrator/accounts` `{email, password (8–72), company_name}`. Use an email with **no seller account**. The email must be confirmed before sign-in. [docs Quickstart, Integrator onboarding]
- **Approval:** "Your account is approved once 10 of your files are approved." You submit ready quotes as an approval request; "**People review them file by file**, which usually takes 24 to 48 hours." [docs File requirements, Submit sample files]
- **Before approval:** "you can quote 25 files per round and a daily number of quotes (`daily_quote_limit_reached` resets at midnight UTC); after approval quotes are unlimited." [docs Business guide] `uploads.limit` = 25 per round; a quote that ends `failed` is given back to the allowance; no quoting while a request is `in_review` (409 `approval_in_review`). [docs Quotes, Integrator onboarding] **The daily number is not stated anywhere**. [unverified]
- **Ordering** needs approval (422 `quote_not_approved` otherwise) and business billing details with a tax registration (a sole trader is fine). Otherwise 403 `compliance_blocked`; `order_blockers: ["billing_details_missing"]` on onboarding. Outside the EU and UK a W-9, W-8BEN or W-8BEN-E is needed (`tax_form_required`). An EU Responsible Person is needed only for **checkout mode** to EU/UK buyers from outside the EU/UK. [docs Business guide, Errors]
- **$15 sample credit** "when your account is approved … valid for 30 days", for `use_sample_credit: true` on a **wallet** order **shipped to your own country**. [docs Business guide, FAQ]
- "**Order to Quote ratio 1:1500.**" This sentence appears once, in the Quickstart, with no explanation. [docs Quickstart] It reads like an expected ratio (up to 1,500 quotes per order) and maybe a fair-use limit. **Ask 3DAPI.** [unverified]

### 1.5 Can a designer key price arbitrary files? **No, not in v2.**
- `create_quote`, `get_quote`, `list_quotes`: "Integrators only; designers are refused with `actor_not_allowed`." [docs Quotes], [spec `x-audience: ["integrator"]`]
- `create_upload` purpose `quote_file`: "Designers may use every purpose except `quote_file` and `withdrawal_invoice`" → 403 `purpose_not_allowed`. [docs Uploads]
- `estimate_integrator_order_shipping` (the only shipping estimate built from a file): integrator only. [spec]

**Ways a designer could get a price:**
1. **Read the prices of products already on 3DAPI. This works, read-only.** GET `/v2/products?sku=<SKU>&expand[]=variants` (`products:read`). The match is exact and ignores case [docs Orders from any platform]. Each variant has `pricing.costs` = `{manufacturing, extra_parts, platform_fee}` (null until priced) and `shipping` = `{tier, determined_by, chargeable_weight_grams, extra_small}` [docs Products: variant object]. Combine it with the public `GET /v2/shipping/quote?country=&tier=&additional_items=` to get print + shipping. This only covers models the seller has already listed on 3DAPI and that 3DAPI has priced. Designer API orders are charged "manufacturing plus platform fee" per unit [docs Orders: `unit_price`]. The platform fee is the plan commission (10%/8%/5%) on the variant's **sales price** [web /pricing, /help/seller-guide]. [inferred: the variant's `manufacturing + extra_parts + platform_fee` is what `create_order` charges per unit; confirm on a live order.]
2. **Create a private product to get it priced.** POST `/v2/uploads` (`design_file`, .3mf/.stl/.obj ≤ 150 MB) then POST `/v2/products` with a design and a variant. This "Counts toward your plan product limit" (Free plan: 10 listings [web /pricing]), and "its designs are pending review by 3DAPI". The help site says an automated printability and auto-pricing check runs first, and an admin reviews only if it fails (1–2 days) [web /help/seller-guide]. **Not suitable for quoting**: it writes to the seller's catalogue, uses plan quota and may put people in the loop. A product can be deleted, but the docs don't say whether that frees the quota. [unverified]
3. **Deprecated v1 designer quotes:** `POST /v1/quotes/upload_file` → PUT to S3 → `POST /v1/quotes {s3_key}` → `GET /v1/quotes/{publicId}`, which gives a `result` per-unit USD **decimal** price and `metrics` (filament weight, print time). Requires key permission **`PRICING` or `FULL`**, and designers have a "global daily limit on quote submissions" (`X-Daily-Quotes-Remaining` header) [docs Quotes (API v1)]. v2 says legacy permissions belong to "keys created before per-resource scopes" [docs Authentication], so **new designer keys probably can't get `PRICING`** [inferred, unverified]. It is deprecated and, per the changelog, "keeps working" for now. Don't build on it.
4. The website's `/integrations/api` page still advertises the v1 designer quote flow ("Upload a 3D model and get an instant quote", `/quotes/upload_file`, `/designer/orders`) [web], which contradicts v2. See §9.

### 1.6 Which account fits a Plinth user?
3DAPI's own guidance points a seller who designs a catalogue and sells on Etsy/Shopify to a **seller (designer) account** [docs Quickstart]. That account **cannot quote files through v2**. A designer sells by uploading products for review, matching Etsy/Shopify SKUs to variants and placing orders by variant (`create_order`). That model doesn't match Plinth's Slant flow ("upload a file, estimate, draft, pay").

The **integrator** account has exactly Plinth's Slant flow (upload a file → quote → shipping estimate → wallet order to the buyer's address). Nothing found stops an Etsy seller from signing up as an integrator under a separate email, but it carries:
- a separate account, and no seller features (no storefront, Shopify/ShipStation import or stock);
- a human review of 10 files before any order can be placed;
- 25 quotes per round and an unstated daily cap until approval;
- business billing details with a tax registration (and a W-8BEN outside the EU/UK) before ordering;
- the unexplained "1:1500" order-to-quote ratio.

**Answer:** For price comparison of arbitrary library models, Plinth needs an **integrator key**. A designer key can only price products already listed and priced on 3DAPI (option 1). A Plinth user who already sells on 3DAPI as a designer **cannot also be an integrator with the same email**.

---

## 2. Quote flow (integrators)

### 2.1 `create_upload`: POST `/v2/uploads` [docs Uploads], [spec]
- Headers: `x-api-key`, `Content-Type: application/json`, optional `Idempotency-Key` (1–255 characters).
- Body (all required): `purpose` (enum `extra_image | product_image | design_file | order_file | attachment | qc_photo | compliance_document | quote_file | withdrawal_invoice`), `file_name` (1–255; the extension must suit the purpose **and match `content_type`**), `content_type`, `size_bytes` (≥ 1, exact).
- **`quote_file`:** extensions `.stl .3mf .obj .step .stp`; types `model/stl, model/3mf, model/obj, model/step, application/step, application/sla, application/vnd.ms-pki.stl, application/octet-stream`; ≤ **262,144,000 bytes (250 MiB)**. Integrators only, with `quotes:write`. [docs]
- Returns **201**:
```json
{ "id":"upl_…", "object":"upload", "purpose":"quote_file",
  "upload_url":"https://<storage host>/…?signature=…", "method":"PUT",
  "headers":{"Content-Type":"model/stl"}, "expires_at":"2026-10-15T10:00:00Z" }
```
- Step 2: **presigned PUT** of the raw bytes (not multipart) to `upload_url` with `method` and `headers` "exactly as given". The bytes go straight to storage, never through the API [docs]. The storage host is not documented (the example is `files.example.com`; v1 used `s3.eu-central-1.amazonaws.com`). Don't send `x-api-key` to it [inferred].
- **Expiry:** "uploads last 24 hours"; unused uploads are deleted [docs Errors `upload_expired`, Uploads]. Each upload ID works **once** (`upload_already_used`) [docs Quotes].
- File contents are checked only when a write uses the upload: 422 `invalid_file` with `details.expected` [docs]. **The spec's `create_quote` 422 codes leave out `invalid_file`** [spec].
- No endpoint deletes an upload or a quote [spec: no DELETE on `/v2/uploads` or `/v2/quotes`].
- Errors: 403 `purpose_not_allowed` / `missing_scope` / `credential_not_allowed`; 422 `file_type_not_allowed`, `file_too_large`; 429.
- Rate limits: 500/min **and** the 60/min "expensive_write" bucket [spec `x-ratelimit`].

### 2.2 `create_quote`: POST `/v2/quotes` [docs Quotes], [spec]
- Body: `{ "file": { "upload": "upl_…" } (required), "name": "1–200 chars" (optional) }`. There is **no quantity, material, colour, units or scale parameter.** Units are whatever the file says (not documented for STL/OBJ). [spec, inferred]
- Returns **201** with the quote object in `status: "processing"`. It is **asynchronous**.
- **Cost:** "Quoting is free." [docs Business guide] It **counts against the allowance before approval** ("A quote counts from the moment it is created, while it is processing and once it is ready; a quote that ends `failed` is given back"). It also counts toward the 60/min expensive_write bucket. [docs Quotes], [spec]
- Errors: 409 `upload_limit_reached` (the round's 25 are used up) or `approval_in_review`; 422 `unknown_upload`, `upload_expired`, `upload_purpose_mismatch`, `upload_missing`, `upload_already_used` (+ `invalid_file` per docs); **429 `daily_quote_limit_reached`** (before approval; midnight UTC) or `rate_limited`.
- **Side effects:** the uploaded file is kept and downloadable through `file.download_url`. 3DAPI may prepare a `production_version` (a .3mf with printer settings) [docs Quotes]. Before approval the quote can be submitted for human review; it is reviewed **only if submitted** in an approval request. After approval, "new quotes stay `not_submitted` and are not reviewed one by one" [docs Quotes `approval`]. Each quote also feeds the integrator analytics (quote volume and value) and, presumably, the order-to-quote ratio [docs Analytics, inferred].

### 2.3 `get_quote`: GET `/v2/quotes/{id}` (`quotes:read`)
- **Poll guidance:** "every few seconds is enough" [docs Quotes]. The Arazzo recipe retries every 5 s, at most 120 times (10 min) [docs Quote a model file]. Slicing "usually takes one to a few minutes" [docs Quotes]. **Webhooks** `quote.ready` / `quote.failed` exist, but webhook endpoints are created only from a dashboard session and need a public https URL (`webhook_url_not_allowed`), so they're unusable for a desktop app. Polling `get_quote`, or `list_events?type=quote.ready` (`webhooks:read`), is the option [spec, inferred].
- `status` ∈ `processing | ready | failed` [spec `QuoteStatus`].
- Result (trimmed, [docs Quotes], [spec `Quote`]):
```json
{ "id":"qte_…", "object":"quote", "name":"Phone stand v2",
  "file":{ "name":"phone-stand-v2.3mf", "size_bytes":2758723,
           "download_url":"<signed, 15 min>",
           "production_version":{ "name":"…", "format":"3mf", "size_bytes":2913004,
                                  "download_url":"<signed, 15 min>", "prepared_at":"…" } },
  "status":"ready",
  "price":{ "amount":1245, "currency":"usd" },
  "suggested_materials":[ { "slot":1, "file_color":"#C12E1F", "file_filament_type":"PLA",
       "material":{ "id":"mat_…","object":"material","name":"PLA Red","custom":false },
       "match":"exact" } ],
  "failure_reason":null,
  "approval":{ "status":"not_submitted", "reason":null },
  "created_at":"…", "finished_at":"…" }
```
- `price`: "**Price to print one unit** of the model, in usd", for the file that gets printed. It is null until `ready` and on `failed` [docs]. "Larger quantities cost less per unit as plates fill, so price an order with its real quantity" [docs Business guide]. **There is no endpoint to price a quantity other than 1 before ordering.** The order's `production_unit_price` "falls as a plate fills" and "already includes the platform fee" [docs Integrator orders]. Whether `price` itself includes the platform fee isn't stated directly. [inferred: yes, since the price at quantity 1 should equal `production_unit_price` at quantity 1]
- **No per-material price, no lead time, no weight, print time or shipping tier on the quote** [spec]. Lead time is only stated in general terms: production in 3–5 business days, delivery in 1–3 local / 5–10 international [docs Business guide]. Whether PETG costs more than PLA is unknown: the quote has one price and the order takes materials separately [unverified].
- `suggested_materials` (null until ready): one entry per extruder slot used (slots may have gaps). `match` ∈ `exact | close | approximate`. STL/OBJ/STEP have no colour (`file_color: null`), and the suggestion falls back to PLA [docs Quotes].
- `failure_reason`: text for people (for example, binary STLs with zero normals are mistaken for text STLs) [docs].
- `approval.status` ∈ `not_submitted | in_review | approved | rejected` [spec].

### 2.4 `list_quotes`: GET `/v2/quotes` (`quotes:read`)
Newest first. Filters: `status[]`, `approval_status[]`, `created_after`, `created_before`, `limit` (1–100), `cursor` [spec]. Useful to find an existing quote before creating a duplicate.

### 2.5 Recommended Plinth flow [inferred]
1. Cache `qte_` IDs keyed by the SHA-256 of the exact file bytes, so a model is quoted once, not once per comparison. Ready quotes don't change. Look the hash up locally before uploading again.
2. POST `/v2/uploads` (Idempotency-Key) → PUT the bytes (no API key, redirects refused) → POST `/v2/quotes` (Idempotency-Key) → poll GET `/v2/quotes/{id}` every 5 s, then back off, with Stop available.
3. Shipping: POST `/v2/integrator/orders/shipping-estimate` with `{country, items:[{quote, quantity}]}`.
4. Show "3DAPI: print $X.XX (1 unit) + shipping $Y.YY to CC, USD, VAT not included". For quantity > 1, label the print price as an upper bound per unit.

---

## 3. Shipping price

### 3.1 `get_shipping_rates`: GET `/v2/shipping/rates?country=XX` (public, 120/min per IP)
Returns the rate card: `currency`, `tiers[] {tier, max_weight_grams}`, `extra_small_max_weight_grams` (100), `zones[] {code, name, countries[], rest_of_world, base_price{small,medium,large}, per_additional_item}` [docs Shipping], [spec]. **Live card (30 Oct 2026, USD cents, small/medium/large, each additional item)** [live]:

| zone `code` | countries | small | medium | large | +item |
|---|---|---|---|---|---|
| us | US | 749 | 999 | 1499 | 100 |
| uk | GB | 699 | 999 | 1699 | 100 |
| australia-nz | AU, NZ | 949 | 1299 | 1999 | 100 |
| eu-core | DE NL BE PL RO BG HU CZ GR SI HR | 599 | 799 | 1299 | 100 |
| eu-mid | FR ES IT AT LU PT CH AL IE | 899 | 1099 | 1599 | 100 |
| eu-north | DK FI SE LV LT EE NO | 999 | 1599 | 1999 | 100 |
| canada | CA | 1499 | 1699 | 2499 | 100 |
| rest-of-world | (all others) | 1599 | 1999 | 2999 | 100 |

It matches the table on www.dapi.digital/pricing [web]. Tiers: small ≤ 600 g, medium ≤ 2,000 g, large above, by the greater of actual and volumetric weight (L×W×H cm / 5000) [docs Business guide].

### 3.2 `get_shipping_quote`: GET `/v2/shipping/quote` (public)
- Query: `country` (required, `^[A-Z]{2}$`, a real ISO code), `tier` (required, `small|medium|large`; no `extra_small`), `additional_items` (0–1000, default 0, extra-small items excluded) [spec].
- Live response for `country=US&tier=small` [live]:
```json
{"object":"shipping_quote","zone":{"code":"us","name":"US"},"country_code":"US","tier":"small",
 "base_price":{"amount":749,"currency":"usd"},"additional_items":0,
 "per_additional_item":{"amount":100,"currency":"usd"},"total":{"amount":749,"currency":"usd"}}
```
- Errors [live]: `country=us` (lower case) → 400 `validation_failed` (pattern). `country=XX` → 400 `validation_failed` ("is not an ISO 3166-1 alpha-2 country code"). `country=RU` → **422 `shipping_destination_not_served`**, refusing Russia, Belarus, Iran and Syria. 404 `shipping_zone_not_found` happens only if 3DAPI disabled the rest-of-world zone [docs].
- **This needs the tier, which an integrator quote doesn't expose.** A designer gets it from `variant.shipping.tier`. Plinth could also estimate the tier from its own mesh volume and bounding box, but that is a guess [inferred].

### 3.3 `estimate_integrator_order_shipping`: POST `/v2/integrator/orders/shipping-estimate`
- Integrator, `orders:read`; "Nothing is created, and your account does not need to be approved yet" [docs]. Accepts `Idempotency-Key` [docs]. Rate limit 500/min only [spec].
- Body: `{ "country": "DE", "items": [ { "quote":"qte_…", "quantity": 1–10000, "extras":[{"extra":"xtr_…","quantity_per_unit":1–100}] } ] }`. Every quote must be `ready`; materials and prices are not sent [docs].
- Response: `{ "object":"shipping_estimate", "country_code":"DE", "zone":{"code","name"}|null, "tier":"small|medium|large"|null, "additional_items":3, "total":{"amount":1099,"currency":"usd"} }`. `zone` and `tier` are null when the order can't be weighed yet (flat rate). **The total is without VAT.** It can change if the rate card changes before ordering [docs].
- Errors: 404 `quote_not_found`; 422 `quote_not_ready`, `quote_rejected`, `extra_not_found`, `extra_not_approved`, `shipping_destination_not_served`.
- **The estimate reveals the shipping tier for a quote.** That is the only way an integrator learns a quote's weight class [inferred].

---

## 4. Materials

- GET `/v2/materials` (public, paged, `limit` ≤ 100), GET `/v2/materials/{id}` [docs Materials].
- Object: `{ id: "mat_…"|null, object:"material", name, custom:bool, technology:"fdm"|null, color, color_hex:"#RRGGBB"|null, filament_type:"pla"|"petg"|… }` [spec].
- **Live catalogue (30 Oct 2026): 23 materials, one page** [live]. PLA (12): Black, Blue, Brown, Clear, Gray, Green, Orange, Pink, Purple, Red, White, Yellow. PETG (11): Black, Blue, Clear, Gray, Green, Orange, Pink, Purple, Red, White, Yellow. `filament_type` ∈ {`pla`, `petg`}. Only FDM is offered ("We do not offer resin, metal, painting…") [web /integrators].
- **How they map to quotes:** materials are **not** chosen at quote time. At order time each line sends either `use_suggested_materials: true` or `materials` as `[{slot, material}]` (or a plain list of IDs when the slots run 1..n without gaps), one per slot in the quote's `suggested_materials` (`material_slots_mismatch` with `details.expected_slots` otherwise) [docs Choose the materials]. Up to 4 colours (slots) per file [docs File requirements]. Custom (non-catalogue) materials exist only for designers [docs Designs].
- Material IDs are opaque and differ from the docs' example ID [live]. Never hard-code them. Look them up by `filament_type` + `color` [inferred].
- Plinth's Slant material picker won't map one-to-one. Map by type and colour name [inferred].

---

## 5. Auth, errors, rate limits, idempotency

### 5.1 Keys
- Header `x-api-key`. Integrator keys look like `sk_` followed by 64 lower-case hex characters (the example secret is `sk_3f9a…41`, 67 characters). The dashboard shows a `preview` such as `sk_3f9a1c2b7...` [docs API keys]. **Designer key format is undocumented** [unverified]. Redaction: mask `sk_[A-Za-z0-9]+`, and every `x-api-key` value, whatever its format [inferred].
- Keys are created and revoked only in the dashboard (an API key cannot manage keys) [docs]. The secret is shown once.
- Docs: "Keep it on your server… Never put a key in browser or mobile code." [docs Quickstart, Authentication] See §8 for a desktop app.
- **Test a key:** GET `/v2/me` → `{object:"actor", user_id, kind:"designer"|"integrator", authenticated_with:"api_key"|"session"|"oauth", scopes, effective_scopes, approval:"pending"|"approved"|"rejected"|null}` (approval is null for designers) [docs Identity]. 401 → `missing_credentials` / `invalid_api_key` / `invalid_session` / `ambiguous_credentials`; 403 → `account_blacklisted`. Plinth should check `kind == "integrator"` and that `effective_scopes` include `quotes:write`, `quotes:read` and `orders:read`, and show `approval`. For the allowance use `get_integrator_onboarding` (`uploads.used` / `uploads.limit`, `status`, `order_blockers`) [inferred].
- **Health:** GET `/v2/health` (public, no rate limit) → `{"status":"ok","database":"up","checked_at":"2026-10-30T21:42:13.550Z"}`; 503 with `status: "degraded"` [docs], [live]. The live 200 carried **no** X-RateLimit headers, as documented.

### 5.2 Error body (v2)
```json
{ "status_code":422, "error":"Unprocessable Entity", "code":"shipping_destination_not_served",
  "message":"3DAPI does not deliver to Russia. We deliver worldwide except Russia, Belarus, Iran and Syria.",
  "details":{ "country_code":"RU", "request_id":"req_…" } }
```
[live]. Branch on `code` (stable), never on `message` [docs Errors]. `details.errors[]` = `{field, message}` on `validation_failed` [live]. `details.fix_url` appears for dashboard-fixable refusals [docs]. (The v1 body differs: `{statusCode, error, message}` [docs v1].)

Codes Plinth must handle for comparison: `missing_credentials`, `invalid_api_key`, `ambiguous_credentials`, `missing_scope`, `actor_not_allowed`, `credential_not_allowed`, `account_blacklisted`, `purpose_not_allowed`, `file_type_not_allowed`, `file_too_large`, `unknown_upload`, `upload_expired`, `upload_missing`, `upload_already_used`, `upload_purpose_mismatch`, `invalid_file`, `upload_limit_reached`, `approval_in_review`, `daily_quote_limit_reached`, `quote_not_found`, `quote_not_ready`, `quote_rejected`, `shipping_destination_not_served`, `shipping_zone_not_found`, `validation_failed`, `idempotency_key_reused`, `rate_limited`. The full table (≈ 140 codes) is in docs Errors "Every error code"; the spec carries them per response as `x-error-codes`.

HTTP meanings: 202 means accepted, with an empty body; 402 means payment failed or the balance is too low; 409 means a state conflict; 503 means retry with backoff [docs Errors].

### 5.3 Rate limits [docs Rate limits], [spec `x-ratelimit`], [live]
- 500/min per API key for every authenticated call. **Also 60/min per key** ("expensive_write") for `create_quote`, `create_upload`, `create_order`, `cancel_order`, `create_integrator_order`, `cancel_integrator_order`, `create_stock_purchase`, card setup, top-ups and withdrawals.
- Public catalogue and shipping reads: **120/min per IP**. Sign-up: 10/hour per IP. Resend: 5/hour per IP. `get_health` and the OpenAPI document are not limited.
- Fixed windows. Headers `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset` are reported "for the limit closest to being reached".
- **`X-RateLimit-Reset` is Unix SECONDS** [docs, spec header description]. Confirmed live: `date: 21:42:15 GMT`, `x-ratelimit-reset: 1793396595` = 21:43:15 UTC, the end of the 60 s window [live]. (Slant uses epoch **ms**; don't share the parser without a unit switch.)
- 429 → `code: "rate_limited"`, header **`Retry-After` in seconds** (sent with 429 only), `details` = `{limit, window_seconds, reset_at (ISO), retry_after_seconds, policy, request_id}` [docs]. "A refused request does not count. A request replayed with the same Idempotency-Key counts like any other request." [docs]
- `daily_quote_limit_reached` is **also 429** but resets at midnight UTC. Branch on `code`, not on the status [docs].
- The spec declares the rate-limit headers only on 4xx responses, but live 200s carry them (except health) [spec, live].

### 5.4 Idempotency [docs Idempotency]
- Header `Idempotency-Key` (1–255 characters [spec]), accepted on the writes listed in the guide, including `create_upload`, `create_quote`, `create_integrator_order`, `estimate_integrator_order_shipping` and `cancel_integrator_order`.
- "Sending the same request again with the same key **within 24 hours returns the first response** without doing anything twice. Reusing a key with a different body is refused with `idempotency_key_reused`. **A refused request (4xx) frees the key** so you can correct and resend it; **a server error (5xx) is kept and returned again**, because the write may already have happened: check the resource before retrying with a new key."
- A replay is probably flagged by the `Idempotent-Replayed` response header (exposed via CORS, undocumented) [live, inferred].
- **For Plinth:** the docs encourage automatic retries ("wait and retry … send the same Idempotency-Key", and the Arazzo recipes retry `>= 500` three times). Plinth's rule is no automatic retry of mutations. Keep it. Always send a fresh UUID key per user action, keep it in memory for that action, and reuse it only on an explicit Try Again within 24 h.

### 5.5 Errors and retry policy (docs) vs Plinth
"A `4xx` other than `429` will fail again until the request changes … A `429` or `503` is temporary: wait and retry with exponential backoff" [docs Errors]. For quotes, Plinth should stop after a 429 (as for Slant) rather than loop.

---

## 6. Money
- Integer minor units plus a lower-case ISO currency. "Every amount is `usd` today" [spec, docs]. Quotes are "in usd". Non-USD sales prices → `currency_not_supported` [docs].
- Quote: `price` per unit only. Shipping estimate: `total`, **excluding VAT** [docs].
- Order charges: `charges = {paid_by, items, shipping, vat{amount, rate 0–1, included, country}, sample_credit|null, total}`. "VAT on the order. Zero outside the EU and UK" [docs Orders]. Wallet mode: VAT is charged on **wallet top-ups** to EU/UK businesses without a confirmed VAT number (reverse charge with a VIES-confirmed number); businesses outside the EU and UK pay no VAT [docs Business guide, FAQ]. Checkout mode: VAT is added for EU/UK buyers, and "There is no US sales tax" [docs].
- Import duties: "Where there is none [production centre] in the buyer's region, they ship from the closest one and import duties are paid by the buyer on delivery" [docs Business guide].
- v1 money is **decimal USD** (`result: 12.34`) [docs v1]. Don't mix them.

---

## 7. Ordering (later, not part of the price-comparison build)

### 7.1 Integrator: `create_integrator_order`, POST `/v2/integrator/orders` (`orders:write`, Idempotency-Key, 60/min bucket)
- Requires an **approved** account (`quote_not_approved`), ready quotes, and billing details (`compliance_blocked`) [docs].
- Body [docs], [spec]:
```json
{ "mode":"wallet",
  "items":[ { "quote":"qte_…", "quantity":1,
              "materials":[{"slot":1,"material":"mat_…"}]   // or "use_suggested_materials": true (not both)
              /* "extras":[{"extra":"xtr_…","quantity_per_unit":1}] */ } ],
  "shipping_address":{ "line1":"…", "line2":null, "city":"…", "state":null,
                       "postal_code":"…", "country_code":"DE" },
  "customer":{ "name":"…", "email":"…", "phone":null },
  "reference":"ETSY-3141592653", "customer_notes":null, "use_sample_credit":false }
```
  Limits: 1–100 lines, 1–10,000 units per line. `customer.email` is required. `country_code` is upper-case ISO alpha-2. `customer_notes` ≤ 2000 characters. `checkout` and `unit_sales_price` are only for `mode:"checkout"`.
- **Charges immediately** in wallet mode: "The order comes back paid, numbered `2AP...`, and goes to production. If payment fails, no order is created." A shortfall is charged to the saved card, with VAT on the top-up [docs]. **There is no draft state and no separate pay step.** Plinth's "create draft, then review and pay" becomes a single irreversible POST [inferred].
- Checkout mode: returns `awaiting_payment`, `2AC…`, and `checkout.url`, open for 24 h. 3DAPI is merchant of record; card fees are EU 1.5% + $0.30, UK 2.5% + $0.30, elsewhere 2.9% + $0.30 [docs].
- Errors: 402 `payment_failed` / `insufficient_balance`; 403 `compliance_blocked`; 404 `quote_not_found`; 409 `production_unavailable`; 422 `quote_not_ready`, `quote_rejected`, `quote_not_approved`, `material_not_allowed`, `material_slots_mismatch`, `suggestions_unavailable`, `currency_not_supported`, `sales_price_below_production`, `shipping_destination_not_served`, `vat_number_invalid`; 503 `card_payments_unavailable`.
- Duplicate guard: `reference` is "Your own order id, for matching", and `list_integrator_orders?reference=` does an exact match. **Unlike the designer `create_order`, the docs do not say an integrator `reference` must be unique** (no `reference_in_use` listed for it) [docs, spec].
- **Unknown outcome:** a 5xx is "kept and returned again" for the same Idempotency-Key, and the docs say "check the resource before retrying". Plinth's unknown-outcome lock applies: look the order up by `reference` before anything else [inferred].

### 7.2 Statuses (`OrderStatus`) [docs Orders / Integrator orders]
`awaiting_payment` (unpaid), `paid` (waiting for a partner), `assigned` (partner has it, not started), `in_production`, `shipped` (`shipping` has tracking), `completed` (delivered and settled), `on_hold` (not enough stock), `rejected` (a partner refused it; 3DAPI reassigns, or cancels and refunds), `returned`, `cancelled`. Lifecycle: `paid → assigned → in_production → shipped → completed` [docs Business guide].

### 7.3 Cancel: POST `/v2/integrator/orders/{id}/cancel` (`orders:write`, Idempotency-Key)
Only `awaiting_payment` (the checkout link closes) or `paid` that "a production partner has not started" (refunded in full to the wallet, or to the card in 5–10 business days). Otherwise 409 `order_not_cancellable`, and email contact@dapi.digital [docs]. Note `assigned` comes before production starts, but cancel names only `paid` [docs]. Treat `assigned` as not cancellable [inferred].

### 7.4 Tracking and following orders
`shipping = {tier, carrier, tracking_number, shipped_at}`. The carrier is a plain name (for example `DHL`), and there is **no tracking URL** [docs Business guide]. Plinth can't receive webhooks (they need a public https endpoint). Poll `list_integrator_orders` (`status[]`, `created_after/before`, `reference`, `quote`, `search`, `expand[]=items`, cursor paging), or the 30-day `list_events` log (`webhooks:read`, filter `type`) [spec]. Webhook signature: `X-Dapi-Webhook-Signature: sha256=<hex>` over `<timestamp>.<raw body>`, `X-Dapi-Webhook-Timestamp` (Unix s), `X-Dapi-Event-Id`; retried for 24 h [docs Webhooks].

### 7.5 Designer ordering (if the user stays a designer)
POST `/v2/orders` (`orders:write`): `items[{variant:"var_…", quantity:1–1000, file?:{upload}}]`, `customer{name, email, phone?}`, `shipping_address{…}`, `reference` (**unique among non-cancelled orders** → 409 `reference_in_use`, nothing charged; letters, digits, `-`, `_`), `customer_notes`, `discount_code`, `use_sample_credit`. It "comes back paid" and charges immediately [docs Orders]. Cancel only while `paid` (`order_not_cancellable` otherwise; v1-created orders can't be cancelled through v2) [docs].
- **Order with a custom file (designers):** a line may print an `order_file` upload (.3mf/.stl ≤ 1 GiB) instead of the variant's design, but "Custom files are turned on per account: ask contact@dapi.digital" (403 `custom_files_not_enabled`). "The variant must be a single design, and its production price is what the line costs, so the file should weigh about the same as the design it replaces. **Files are not reviewed or re-sliced**." [docs Order with a custom file] This is the only designer path to printing an arbitrary file, and the price comes from an existing variant, not from the file.

---

## 8. Privacy and terms
- **Uploaded files:** each quote keeps the original file and the production version, both downloadable through signed links that last 15 min [docs Quotes]. **There is no API to delete quotes or used uploads** [spec]. Unused uploads are deleted after 24 h [docs]. Retention of quote files is **not documented** [unverified]. The help site (written for seller designs) says: "The designer/seller retains full ownership … 3DAPI receives only a license to print and fulfill it. The designer/seller can request full deletion of any and all models from our systems and any partner systems at any time" (by request, not API). "Only the matched production center receives the print-ready file for an active job. Access is revoked once the job is complete." [web /help/policies] Before approval, **people review files submitted for approval** [docs]. The team "can now replace" a design file during review, with an email [web changelog]. Whether integrator quote files are used for anything else isn't stated [unverified].
- **Request logs:** integrators can read "The requests you made in the last 30 days, **with bodies**", plus IP, `User-Agent` and the Idempotency-Key [docs Logs]. 3DAPI therefore stores request bodies, including order customer data, for 30 days.
- **Customer data:** GDPR, with the Romanian branch as the EU data processing entity; encrypted at rest and in transit [web /help/policies]. In checkout mode 3DAPI emails the buyer directly, naming you as the seller [docs Business guide].
- **Keys on the desktop:** the docs say "Keep it on your server … Never put a key in browser or mobile code." [docs] That advice is about third parties extracting a developer's key. In Plinth's case the account owner keeps their own key in their own Keychain, and 3DAPI's own Claude Desktop extension does the same ("Claude Desktop keeps it in your system's secure storage") [docs MCP]. Advise users to create a **dedicated, least-scope key** (`quotes:read`, `quotes:write`, `orders:read` for comparison) that they can revoke [docs MCP, inferred].
- **Terms of Service:** /terms, /privacy and similar are client-rendered, and no text could be fetched without a browser [web]. **No branding or attribution requirement appears** in the API docs. Third-party clients aren't addressed [unverified]. Footer documents exist: Terms of Service, Privacy Policy, End Customer Purchase Terms, Seller/Designer Agreement and others [web]. Have the owner read the Terms before shipping.
- Plinth should also send `User-Agent: Plinth/<version>`. The logs show it to the user [inferred].

---

## 9. Surprises and contradictions
1. **v2 and the integrator type are one day old** (changelog 30 Oct 2026) [web].
2. **The website's API page still sells the deprecated v1 designer quote API.** `/integrations/api` lists `POST /quotes/upload_file`, `/designer/orders`, webhook names `quote.completed` and `order.shipping`, "volume pricing" and "Instant" quotes [web], while v2 refuses designers for quotes [docs]. The help seller guide also says to get approval by creating "at least 10 quotes … via the Quotes endpoints" (v1) [web /help/seller-guide].
3. **Allowance wording varies.** "25 files per round" (Business guide, FAQ), "25 quotes per round" (Quotes, onboarding `uploads.limit`), and "You used the 25 uploads of this onboarding round" (`upload_limit_reached`) [docs]. The daily quote number is never given.
4. "**Order to Quote ratio 1:1500**" (Quickstart only) is unexplained [docs].
5. **Volume pricing is claimed but can't be priced in advance.** Quote `price` is one unit; the order's per-unit price "depends on" quantity, and no preview endpoint exists [docs]. The website promises "volume pricing for larger quantities" in quotes [web /integrations/api]; that refers to v1 [inferred].
6. **The quote spec leaves out `invalid_file`**, which the docs say `create_quote` returns [spec vs docs].
7. **Rate-limit headers:** the spec declares them only on 4xx, but they appear on 200s [live]. Docs: "Every limited response carries" them.
8. **`estimate_integrator_order_shipping`** is listed as accepting `Idempotency-Key` although it creates nothing. Its `x-ratelimit` doesn't include the 60/min bucket [docs, spec].
9. **Example bugs:** the `list_integrator_orders` example nests `data` as an array of arrays, and the api-key object example is `null` [docs]. Zone examples ("EU Core" with 5 countries) differ from live ("EU-Core", 11 countries) [docs vs live].
10. **MCP money tools** list only the integrator order and cancel, but "Orders from any platform" calls designer `create_order` a money tool too [docs].
11. **Designer "at cost":** `create_order` says "You pay at cost (production price, shipping and VAT)", but the order item `unit_price` is "manufacturing plus platform fee when you paid" [docs]. The platform fee is a percentage of the variant's **sales price** (10/8/5%) [web /pricing, /help/seller-guide]. So a designer's "cost" for the same model changes with the retail price they set.
12. **Plan prices:** /help/pricing says Growth $29/mo and Scale $99/mo; /pricing shows $24.17/mo and $82.50/mo billed annually ($290 and $990 a year) [web]. Free plan: 10 listings, $15 sample credit once (30 days from sign-up) [web]. That differs from the integrator $15, which starts on approval [docs].
13. `create_integrator_order` checks the request in full **before** the compliance gate, so 422s come before 403 `compliance_blocked` [docs].
14. Cancel rules name only `paid`, although `assigned` ("production has not started") sits between `paid` and `in_production` [docs].
15. The country code must be upper case; `us` is a 400 [live]. Plinth must upper-case it.
16. Quote `production_version` is always a .3mf. A mesh upload "becomes a 3MF project", and 3DAPI adds its own printer settings (Bambu P1S, 0.4 mm nozzle, 0.20 mm layers, supports on the build plate only). File rules: manifold, walls ≥ 0.45 mm, a flat bottom, fits the P1S plate, ≤ 4 colours [docs File requirements, Quotes]. Prices therefore reflect 3DAPI's slicing, not the seller's.
