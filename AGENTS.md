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

- Run `swift test` for the full suite. For model/order/location UI logic, use `swift test --filter 'ModelsUXTests|OrdersUXTests|ShellUXTests|DeliveryLocationTests|ModelLibraryActionsTests|UnknownOutcomeLockTests'`.
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
- `OrderTools.swift`: orders-list typed sort keys, CSV export (addresses opt-in, formula guard), detail facts, copied item options summary and advisory postcode checks.
- `ModelLibraryActions.swift`: model rename/export, cloud–local links, prepared-material mismatch, scale check and scaled copies, and menu helpers (Go shortcuts, modal-presentation guard).
- `EstimateComparison.swift`: Compare estimates sheet — sequential, rate-limit-aware estimate batch (≤ 20 reads, no auto-retry), quantity parsing, per-unit/cheapest/flat-pricing helpers and the explicit **Use** hook.
- `DeliveryLocation.swift`: optional one-shot location lookup and reviewed address mapping.
- `scripts/build-app.sh`: app bundle metadata, including location permission purpose strings.
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
- No menu item or keyboard shortcut may upload, pay or cancel. Menu commands must do nothing while a sheet, alert or dialog is open.
- Geometry changes save separate copies and must retain existing validation; do not weaken checks to make tests pass.

## Documentation

Update README.md for changed user flows, setup or privacy behaviour. Update docs/API_REFERENCE.md for integration changes. Keep this file focused on durable contributor guidance rather than session history or claims that live tests passed.
