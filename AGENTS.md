# Working on Slant Studio

Slant Studio is a native SwiftUI macOS 14+ app built with Swift Package Manager. Read README.md for user workflows and docs/API_REFERENCE.md for the Slant integration contract.

## How work is done

Every task follows this process. Scale the number of agents to the size of the task, but keep every stage. Use the strongest available model (currently Claude Opus 5.5) for every sub agent.

1. **Research and audit in parallel.** One agent studies comparable apps and platform conventions. Another audits the code for gaps, with file:line evidence, and checks each gap against the rules below. Every idea gets a frank verdict: genuinely useful, or polish.
2. **Shortlist.** Drop ideas that are already handled, low in value, or in conflict with "Behaviour to preserve", and record why each was dropped.
3. **Implement in parallel isolated checkouts,** one per non-overlapping file area, each branched from current `main`. Each implementer decides whether its feature is useful before building it, adds tests for new pure helpers, and checks its own work three times:
   - build and the full test suite;
   - its diff against "Behaviour to preserve";
   - an adversarial pass over edge cases.
4. **Merge into an integration branch, then review independently.** Three read-only reviewers each take one focus: correctness bugs; safety and privacy rules; and usefulness/UX, with a KEEP / CHANGE / REMOVE verdict per feature. Give reviewers the code, not the implementers' conclusions.
5. **Apply the findings.** Payment and lock changes get the closest scrutiny. Remove features judged not useful instead of keeping them.
6. **Verify:** full `swift test`, `./scripts/build-app.sh`, `codesign --verify --deep --strict`, and a check that the location permission strings are in the bundle's Info.plist.
7. **Ship.** Scan the outgoing diff for secrets and generated files, then fast-forward `main` and push. There is no CI, so local verification is the only gate.
8. **Report** what shipped, what was cut and why, what is unverified (especially native UI and live Slant responses), and any decision the owner should confirm.

## Build and verify

- Run `swift test` for the full suite. For model/order/location UI logic, use `swift test --filter 'ModelsUXTests|OrdersUXTests|ShellUXTests|DeliveryLocationTests|ModelLibraryActionsTests|UnknownOutcomeLockTests|OrderToolsTests|EstimateComparisonTests|MeshHealthTests|ModelFormatsTests|ModelThumbnailAndTrashTests|CloudFileDetailsTests|MarginTests|SavedProductsTests|OrderImportTests'`.
- Run `./scripts/build-app.sh` to build and ad-hoc sign `dist/Slant Studio.app`. The script verifies the bundle signature and packages resources and the Euclid licence.
- Run SwiftPM builds and tests sequentially; do not edit source files during compilation.
- Report failing tests and unverified live flows explicitly. A successful targeted suite does not establish that the full suite passes.
- Verify native UI changes in the packaged app when computer access is available. `.build/`, `dist/` and `.swiftpm/` are generated and ignored.
- The full suite takes about 20 seconds. If it suddenly takes minutes, or a reinforcement test intermittently fails with "closed manifold", look for geometry output that depends on Set/Dictionary iteration order. Swift randomises hashing per process, and `SWIFT_DETERMINISTIC_HASHING=1` helps confirm the cause. Keep geometry iteration in index order.
- Do not create `StudioStore()` in tests: it reads the real Keychain key and model library. Put UI logic in pure functions and test those.

## Implementation map

- `StudioStore.swift`: shared state, API workflows, delivery details and persistence.
- `ModelsView.swift`: model library, print configuration and the persistent next-action bar.
- `OrdersView.swift`: order composition, duplicate-as-new-draft prefill, the discard check, delivery country defaults and the country list, review and fulfillment actions.
- `OrderTools.swift`: orders-list typed sort keys, CSV export (addresses opt-in, formula guard), detail facts and the marketplace reference from metadata (proper names for import's lower-case `source`; also shown in the orders table), the duplicate-draft guard state and notice, copied item options summary and advisory postcode checks.
- `Margin.swift`: the order-detail Profit check — strict money/percent input parsing, the order's Slant total, fee presets (assumed rates, all editable), typed units sold for per-unit listing fees (not Slant item quantities) and Decimal estimated profit/margin maths. Only the preset and rates are saved.
- `ModelLibraryActions.swift`: model rename/export, cloud–local links, prepared-material mismatch, scale check and scaled copies, and menu helpers (Go shortcuts, modal-presentation guard).
- `OrderImport.swift`: Import Orders — bounded CSV reader (encodings, delimiters, Excel `sep=` line, RFC 4180), Etsy/Shopify/template detection, grouping rows into orders (repeated-row check only on rows carrying delivery details), per-order checks against saved products (units summed per product before resolving; shared once-per-order lines added once), the session-only Match products choices (explicit, never fuzzy, never saved), the session duplicate ledger, the paced, stop-on-unknown draft runner, Show Drafts, and its sheet (Return never creates drafts).
- `EstimateComparison.swift`: Compare estimates — a sequential, rate-limit-aware batch of ≤ 20 estimate reads (never retried) and its explicit **Use** hook.
- `SavedProducts.swift`: saved products (references only — no prices, addresses or customer data), SKU matching and uniqueness, the `savedProductOrderLines` resolver (per-unit vs per-order quantities, flagged in `perOrder`, 10,000 cap, latest upload of linked models, blockers that callers must honour; unloaded catalogs never block) and `products.json` storage (lenient decoding, unreadable files kept as `products.unreadable.json`).
- `SavedProductsView.swift`: the Saved Products sheet and editor (a store-driven sheet counted by `isPresentingSheet`), the composer's **Add Saved Product…** popover (units typed as text and parsed on each change, resolved-lines preview) and their pure helpers.
- `ModelPreview.swift`: the 3D preview, its dimension/build-volume labels and the STL parser (`STLMesh`).
- `ModelFormats.swift`: OBJ and 3MF readers into `STLMesh` (OBJ ear clipping, units, build items, component transforms, production-extension parts) and the format-aware scale check. Keep their size, triangle, depth, placement and triangulation-work limits; a face that can't be split exactly must block STL copies.
- `ZipArchive.swift`: minimal bounded ZIP reader (stored/DEFLATE, ZIP64, CRC, ratio cap) for 3MF packages.
- `ModelFileOpening.swift`: Finder/Dock opens (window raised first, import queued until no modal UI or request is active), modal-guarded File menu actions, and STL copies of OBJ/3MF models.
- `MeshHealth.swift`: advisory mesh check (open, non-manifold and flipped edges, zero-area triangles, shells per 3MF object) and its one-line inspector panel.
- `ModelThumbnails.swift`: software-rendered library thumbnails, their on-disk cache and bounded rendering queue.
- `LibraryTrash.swift`: moving removed library files to the Trash and restoring them for Edit › Undo.
- `DeliveryLocation.swift`: optional one-shot location lookup and reviewed address mapping.
- `StudioView.swift`: the main window — native `List(selection:)` sidebar (Models, Orders, Catalog; a Developer section with API Workbench and Activity only when developer tools are on), the account-status footer that opens Settings, the Connect Slant Account prompt shown without a key, and Activity. Store code asks for Settings with `requestSettings(_:)`; the window owns `openSettings`.
- `SettingsView.swift`: the Settings window (⌘,), the only home for the account — Account (API key, default platform, platforms) and Advanced (usage, rate limit, service status, read-only platform ID, owner ID, billing, Show developer tools). The developer-tools switch waits while a request runs or anything modal is shown, so the Workbench is never torn down mid-review or mid-request.
- `PlatformsSettingsView.swift`: platform list and management in Settings › Account (details, edit, disable, re-enable by ID, test webhook, typed `rotate` secret rotation, failed deliveries and resend) and `PlatformComposerView`. The main window's composer (`showPlatformComposer`, used by the Models action bar) and Settings' (`showSettingsPlatformComposer`) are never shown together. Catalog (in `ModelsView.swift`) holds materials, components and stationery only.
- `scripts/build-app.sh`: app bundle metadata, including location permission purpose strings and the STL/OBJ/3MF document types.
- `Tests/SlantStudioTests/`: workflow, API, UI-logic and geometry tests.

## Behaviour to preserve

- Keep upload, estimate and order-draft actions accessible while scrolling. Explain missing prerequisites and mark estimates stale when their configuration changes.
- Preserve explicit delivery choices. Use the Mac region only as an initial country default; never silently substitute US when it is unknown.
- Request location only after the user's action. Keep manual address entry available, review suggestions before applying them, cancel pending work when the form closes, and ignore callbacks from cancelled attempts.
- Location suggestions must not silently overwrite a form. Applying one keeps name/email but clears the prior unit number. Do not store or log coordinates or add them to Slant requests.
- Location access requires the packaged app's permission descriptions. Do not remove those strings or trigger lookup on app/form launch.
- Slant traffic is production traffic. Preserve explicit charge/cancel review, unknown-outcome locks and credential redaction. Do not automatically retry mutations.
- The unknown-outcome lock is shared between the Orders review sheet and the Workbench, and records the action and the status it was sent from.
  - Only these lift it: a confirmed success, a reload showing that recorded action's outcome, a definite HTTP 4xx refusal (not 408/409), or a failure before sending. Timeouts, transport errors and 5xx keep it.
  - This relies on both paths re-fetching the order before writing: pay requires DRAFT, and cancel requires an unchanged, cancellable status. Keep those checks.
- Draft creation (`POST /orders`) is never retried, automatically or from the alert's Try again. After a create whose outcome is unknown (timeout, transport error, 5xx, 408/409, unreadable reply), every composer shows a notice naming each unconfirmed attempt's recipient and time (in memory only, cleared with the other account write safeguards) and the next Create needs an explicit **Create Anyway**, with Don't Create as the default; only a confirmed creation clears it.
- Profit check uses the order's real Slant total in USD, Decimal money and editable, dated fee assumptions. Never save what the buyer paid or the units sold, or tie amounts to an order on disk.
- Import Orders creates drafts only, one request at a time after an explicit confirmation. It never pays, never retries, and stops the batch at the first unknown outcome (timeout, transport error, 5xx, 408/409, or a reply without an order ID); only a definite refusal lets it continue. Stopping or closing the sheet takes effect before the next request, never mid-request. Drafts are built only through `orderDraftPayload`. Imported names, emails and addresses stay in the sheet's memory: never on disk, in preferences, logs or Activity (counts only). Never invent an email, assume a country, pad a ZIP or match an item to a product without the user's choice; Match products choices stay in the sheet's memory too. Neither the Create button nor its confirmation may take Return.
- No menu item or keyboard shortcut may upload, pay or cancel. Menu commands must do nothing while a sheet, alert or dialog is open in any window, including Settings. Files opened from Finder wait until nothing modal is shown and no request is running.
- Geometry tools stay STL-only. OBJ/3MF models are previewed and uploaded in their original format; the tools work on a separate STL copy.
- Geometry changes save separate copies and must retain existing validation; do not weaken checks to make tests pass.

## Documentation

Update README.md for changed user flows, setup or privacy behaviour. Update docs/API_REFERENCE.md for integration changes. Keep this file focused on durable contributor guidance rather than session history or claims that live tests passed.
