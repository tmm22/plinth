# Working on Slant Studio

Slant Studio is a native SwiftUI macOS 14+ app built with Swift Package Manager. Read README.md for user workflows and docs/API_REFERENCE.md for the Slant integration contract.

## Build and verify

- Run `swift test` for the full suite. For model/order/location UI logic, use `swift test --filter 'ModelsUXTests|OrdersUXTests|ShellUXTests|DeliveryLocationTests|ModelLibraryActionsTests|UnknownOutcomeLockTests'`.
- Run `./scripts/build-app.sh` to build and ad-hoc sign `dist/Slant Studio.app`. The script verifies the bundle signature and packages resources and the Euclid licence.
- Run SwiftPM builds and tests sequentially; do not edit source files during compilation.
- Report failing tests and unverified live flows explicitly. A successful targeted suite does not establish that the full suite passes.
- Verify native UI changes in the packaged app when computer access is available. `.build/`, `dist/` and `.swiftpm/` are generated and ignored.

## Implementation map

- `StudioStore.swift`: shared state, API workflows, delivery details and persistence.
- `ModelsView.swift`: model library, print configuration and the persistent next-action bar.
- `OrdersView.swift`: order composition, duplicate-as-new-draft prefill, the discard check, delivery country defaults and the country list, review and fulfillment actions.
- `ModelLibraryActions.swift`: model rename/export, cloud–local links, prepared-material mismatch, scale check and scaled copies, and menu helpers (Go shortcuts, modal-presentation guard).
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
- Geometry changes save separate copies and must retain existing validation; do not weaken checks to make tests pass.

## Documentation

Update README.md for changed user flows, setup or privacy behaviour. Update docs/API_REFERENCE.md for integration changes. Keep this file focused on durable contributor guidance rather than session history or claims that live tests passed.
