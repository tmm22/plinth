# Slant Studio for Mac

A native SwiftUI macOS client for the [Slant 3D V2 API](https://slant3dapi.com/documentation/introduction). Import a model (STL today in the guided Models UI; Workbench also accepts documented `obj` / `3mf` upload types), preview geometry, upload to your platform, estimate cost, draft an order, and submit for production—with an API Workbench covering every documented operation.

## Run

Requires macOS 14+ and Xcode 16+ / Swift 6. Euclid 0.10.0 is pinned for solid geometry operations; its licence ships with the app.

```sh
swift test
./scripts/build-app.sh
open "dist/Slant Studio.app"
```

Or open `Package.swift` in Xcode / `swift run SlantStudio`. Packaging is ad-hoc signed for the current Mac; public distribution needs Developer ID signing and notarization.

## Connect and print

1. **Connection** — save your API key to Keychain and test; load or create a platform (billing is configured in Slant’s dashboard).
2. **Models** — import/drop an STL for local preview. Use **Optimise for purpose**, choose the part’s use and stress direction where needed, then **Optimise & save copy**. The app remembers the purpose and prepares a rotated STL with its geometry and dimensions preserved. **Upload model** runs presigned upload + confirm. Estimate the prepared copy with material and quantity.
   The next action stays in a fixed bar while you scroll: **Upload model → Get estimate → New Order Draft**. Material and quantity appear directly below the preview, before optional geometry tools. Missing materials and invalid quantities link back to the configuration; previous estimates are labelled when settings change. Re-upload is available in **More actions** and asks for confirmation, because it creates a second file in Slant rather than replacing the first. A prepared copy whose saved material differs from the current selection offers **Use prepared material** under the material picker; the selection never changes on its own.
   **More actions** and a local model's context menu also offer **Rename…**, **Export…** and **Show in Finder**. Renaming changes the library name and later upload names; Slant cannot rename a file that is already uploaded. **Export…** saves a copy (for a slicer or CAD tool) under the model's name; the library file is never moved. Uploaded models that are also in the library show **On this Mac** and offer **Show local copy** before downloading another copy.
   STL files carry no units. If a model's largest dimension is under 3 mm or over 1,000 mm, a notice suggests it may have been exported in another unit. For a plain import, it can save a separately scaled copy (for example ×25.4 for inches), which is parsed and checked before it is added; the original is unchanged. Prepared or edited copies are not rescaled.
3. **Orders** — draft with delivery details and line items. The initial shipping country follows your Mac’s Region setting and stays editable; delivery details reused in the current session take priority. If the region cannot identify a country, choose one explicitly; **Review & place order** charges and starts fulfillment. Cancel requests follow Slant’s cancel/refund rules.
4. **Menus** — **Go** lists every destination (⌘1 Models, ⌘2 Orders, ⌘3 Catalog, ⌘4 Connection). **Model** holds Rename…, Export… (⇧⌘E) and Show in Finder for the selected local model. No menu item or shortcut uploads, places, pays for or cancels anything.
5. **API Workbench** — every catalog operation against production, with parameter validation, JSON bodies, mutation review, typed confirms for high-risk deletes/secret rotation, and secret redaction in responses.

Live traffic uses the **production** API. Mutations are never auto-retried. If a network error leaves a charge or cancel outcome uncertain, Studio locks that order across Orders and the Workbench until you reload it and the result is clear.

## Features

- Local model library with drag/drop, binary/ASCII STL preview (bounded size/triangle limits).
- Purpose-based preparation for brackets, clips, enclosures, decorative and custom parts. Automatically selects among six axis-aligned placements and up to 24 additional surface-normal directions using bed contact, overhangs, height and stress direction; saves a separate binary STL without scaling or reshaping. Purpose, source link, placement and selected material ID persist with the prepared copy. Custom descriptions are saved as context, not interpreted by an AI model. Existing libraries remain compatible. These are geometry heuristics, not mechanical simulation or a guarantee of strength or finished tolerances; production settings remain with Slant. OBJ/3MF and STL files over preview limits require external preparation.
- Presigned direct upload with stage reporting; cloud file list, metrics, estimates, materials/components/stationery browsers.
- Multi-item order drafts, explicit pay confirm with fresh cost preview, cancel with refund-aware copy, activity history.
- Full OpenAPI-backed Workbench (searchable catalog, empty-search state, ⌘Return to fetch/review, no Return on confirm-sheet sends, cross-sheet unknown-outcome lock for charge/cancel, numeric pay totals, metadata/query validation).
- Session-only API-key management links to the dashboard; customer create/checkout not offered by the public API.
- Rate-limit-aware errors; no bearer credentials on storage URLs.

Contributor guidance is in [AGENTS.md](AGENTS.md).

See [docs/API_REFERENCE.md](docs/API_REFERENCE.md) for the endpoint table (Guided / Workbench / Unavailable), doc-vs-spec conflicts, rate limits, and webhook HMAC verification.

## Data and security

- API key: Keychain service `SlantStudio` / account `api-key`.
- Local models: `~/Library/Application Support/SlantStudio/` (files are stored under internal names; use **Export…** for a named copy).
- Optional delivery location: **Use current location** in an order draft requests macOS permission only when pressed. Apple Location Services and reverse geocoding suggest an address for review; **Use this address** fills the editable shipping fields, preserving name/email and clearing the old unit number. No background tracking or coordinate storage is used. Lookup stops when cancelled or the form closes. Coarse/stale fixes, permission denial and missing street addresses fall back to manual entry. The packaged app includes the required permission descriptions; command-line runs explain that the packaged app is required. Address mapping and location-quality checks have automated coverage. Live permission and address lookup still need a walkthrough on a Mac with Location Services available.
- Preferences: UserDefaults (including uploaded models you chose to hide from the library; hiding never deletes anything from Slant). Addresses and response bodies stay in-session memory.
- API: `https://slant3dapi.com/v2/api` (+ documented `/v2/slant/webhook` exception).

## Print-bed placement

Prepared copies sit at Z = 0 and use a flat contact face from the placements evaluated. Edge/point-only contact is excluded; contact area and width relative to height influence ranking alongside support and strength preferences. The preview shows an illustrative bed beneath the prepared model. No bottom flattening, cutting, scaling, brim or raft geometry is added. If none of the evaluated positions provides flat contact within the build volume, custom placement is needed externally. This is a geometric placement heuristic, not an adhesion or warping simulation.

The approach follows [Prusa’s FDM design guidance](https://help.prusa3d.com/article/modeling-with-3d-printing-in-mind_164135) on orientation and bed-facing surfaces, and [Slant’s production guidance](https://www.slantpod.com/post/what-is-slant-3d-s-print-quality) on minimising support and testing actual prints. [Prusa’s warping guidance](https://help.prusa3d.com/article/warping_2011) also makes clear that bed adhesion depends on material, temperature and machine preparation. A larger base alone does not guarantee production reliability. Numerical coplanarity tolerance and ranking weights are app heuristics, not provider specifications.

## Optional edge improvements

Models includes a **Design improvements** check for sharp joins and angled/curved transitions that may already be chamfers or fillets. This is triangle-normal analysis, not recovery of CAD features. It does not claim to identify every fillet or infer mating surfaces. General meshes receive conditional suggestions for editing specific edges in the source CAD model; analysis is limited to 100,000 triangles.

For exactly recognised closed, outward-wound, 12-triangle solid rectangular parts, **Review an edge improvement** offers a 45° bottom chamfer or rounded vertical corners, adjustable in size with a before/after preview. These edits remove material and retain the overall envelope, not the original edge shape or contact area. The user identifies whether the affected edges are non-critical before saving. Detailed, hollow, already treated, open or ambiguous models are never replaced by their bounding box. Generated files are parsed and checked before saving as a separate local model; originals and cloud files remain untouched. Prepared load directions are remapped to the edited model’s axes, and new copies require a new upload and estimate.

The treatment choices follow [Prusa’s fillet/chamfer guidance](https://help.prusa3d.com/article/modeling-with-3d-printing-in-mind_164135) and [Autodesk’s additive design considerations](https://www.autodesk.com/learn/ondemand/curated/design-for-additive-manufacturing-with-fusion/5p0AhR0t0k8663u0OScBmt). External corner rounding is not presented as structural reinforcement; internal load-bearing fillets require the original CAD model and load context.

### Expanded placement and material matching

The placement search groups triangle normals by direction and evaluates the largest groups first, with a maximum of 30 candidates. Every candidate is checked against the whole mesh for actual bed contact and build volume. This is a bounded search, not a global orientation optimum; it does not search in-plane rotations or simulate support removal. Rotations preserve triangle geometry within floating-point precision. Existing six-position recipes remain readable. Oblique load directions are not rounded to an axis when creating an edge-edited copy; the user chooses a new direction when needed.

**Match material to use**, inside **Optimise for purpose**, offers optional room-temperature rigidity (PLA) and toughness/occasional-flex (PETG) guidance. It uses exact catalogue profiles with confirmed availability and changes the selected material only when the user chooses one. Unknown blends receive no inferred rating. Repeated flexing and warm environments require supplier performance data and application testing; the app does not invent fatigue or temperature ratings. The requirement is saved with the part and prepared recipe. Guidance follows [Prusa’s PLA guide](https://help.prusa3d.com/article/pla_2062) and [PETG guide](https://help.prusa3d.com/article/petg_2059); these describe material families, not Slant-specific performance certification.

### Reinforcement copies

**Reinforce this part** is a collapsed optional panel for closed, consistently oriented STL meshes up to 20,000 triangles. It supports internal ribs, triangular gussets, additive inside-junction fillets, mounting collars, overhang support chamfers, wall matching to line width, teardrop hole roofs, counterbore bridging layers, splitting with alignment pins, and three experimental treatments (internal shell gap, hole-wall ring gap, four-cell internal cavities). Operations use Euclid 0.10.0 (MIT, pinned in `Package.resolved`); the licence ships in the app bundle. Features are fused/subtracted as solids rather than exported as overlapping shells.

Choose a treatment, local dimensions, axis direction and a position measured from the model minimum. **Suggest position** tries a bounded 27-position search for a geometric starting point. It is not a stress analysis or a complete search, and it does not infer the space needed by electronics or mating parts. **Update preview** validates the candidate; the user reviews the placement before applying. Keep-clear boxes reject changes to protected regions, and a side-by-side cutaway shows internal changes without cutting the exported part. Suggestions may still need manual placement or CAD work, particularly for off-axis bores and complex joints.

Additive features must overlap existing material, make a measurable change, stay within the original overall envelope and avoid introducing a disconnected body. Mounting collars require a clear nominated bore and a complete annular seat at one end; they never drill an opening. The nominated clearance and protected regions need to include all required counterbores, fastener access and assembly clearance. Inside fillets add material, unlike the existing external-corner rounding tool. Another reinforcement can be added to the resulting copy, with each source version retained; on curved geometry, a repeatedly regenerated copy may instead report that a CAD edit is needed.

Before any solid operation, imported STL triangles are grouped into flat faces and each vertex is moved (by well under 0.1 µm) onto its face planes, with needle-shaped triangles merged into neighbouring polygons. Float STL rounding otherwise leaves faces slightly non-coplanar, which Euclid's Boolean operations turn into open seams around round holes. If a mesh cannot be cleaned this way, the original triangles are used and the exported-copy checks still apply. On export, a thin triangle that rounds to three collinear Float points is replaced by an edge flip with its neighbour rather than dropped, so the seam stays closed.

Print-process treatments depend on the layers, so they stay Z up (use **Turn about Z** to point them) and lock the saved copy's print orientation to Z up:

- **Overhang support chamfer** fills under a ledge with a 45° wedge so it prints without supports.
- **Match wall to line width** measures the wall through the region centre along local Y and thickens its +Y side to a whole number of extrusion lines. The line width (default 0.45 mm) is an estimate, because Slant does not publish its toolpath width.
- **Teardrop hole roof** adds a 45° point to an existing horizontal hole along local X. This enlarges the top of the hole, so avoid it where the top is fit-critical.
- **Counterbore bridging layers** cut a one-layer strip, then a one-layer square, into a downward-facing counterbore ceiling, so each layer bridges between solid edges. Set position Z at the ceiling and the layer height to match the print. This slightly reduces the screw-head bearing area.
- **Internal shell gap** and **hole-wall ring gap** (experimental) cut thin closed gaps inside the part, or around an existing vertical bore, so the slicer prints extra perimeters on both sides. A slicer may merge a gap that is too narrow for its toolpaths.

**Split with alignment pins** cuts the part on the region's local mid-height plane and drills matching blind pin holes in both halves. It saves two part copies, each of which can then be prepared in its own orientation. The joint is weaker than solid material, so keep it away from peak loads.

Teardrop, bridging, ring gap, wall matching and split are placed manually; **Suggest position** is not offered for them.

Internal cells remove material and create internal boundaries; they do not override Slant wall count or guarantee more strength. Their roofs slope at 45 degrees in local Z, so review the final print orientation. A solid surrounding envelope must provide the specified clearance from existing cavities and outer surfaces. Experimental copies require an explicit test-print acknowledgement. There is no automatic “approved” status or inferred strength percentage. All treatments require verification on representative prints before treating them as production-qualified.

Geometry checks cover closed directed edges, winding, envelope, connected-body count, serialized volume and protected-region changes. They do not prove absence of every self-intersection or guarantee finished tolerances, structural performance, adhesion or Slant’s toolpaths. Preview work runs off the main thread, has cooperative cancellation and a time limit, and invalidates on setting changes. Results are saved as separate local STL files with treatment/region metadata, preserving the source; a new upload and quote are required. The displayed geometric volume change is not a filament-use or price estimate. The 1.2 mm feature floor is an app heuristic, not a provider manufacturing specification.

### Auto-improve

**Auto-improve & save copy**, at the top of a local model's details, applies every treatment that the app can place reliably in one click and saves the result as a single new local copy. There is no review step before saving, so check the saved copy's summary and preview before uploading it. **Return to original** goes back to the untouched source.

It first chooses a print orientation for the part's purpose. Prepared copies and copies that are already locked to Z up keep their orientation. It then re-detects features on the current geometry and applies them in this order:

1. **Counterbore bridging layers** in downward-facing counterbore ceilings with two concentric round edges (0.2 mm layers).
2. **Overhang support chamfers** under downward-facing ledges up to 15 mm deep. Deeper ledges, and ledges without enough height below them, are reported for manual work.
3. **Wall matching** for inner walls 0.65–2.7 mm thick, which are thickened inward only to a whole number of 0.45 mm lines. Outer surfaces and the overall envelope are not changed.
4. **Inside-junction fillets** on up to 12 concave edges, longest first, sized from the thinner adjoining wall (1.2–3 mm). Decorative parts receive no fillets.

The copy keeps the orientation it was improved in, because these treatments depend on the layers. Every step goes through the same checks as a manual reinforcement, plus a volume-conservation check. If a step fails, it tries an alternative placement and is otherwise skipped, with the reason listed under **Skipped after checks**. The run stops after four minutes, and **Stop** discards the work without saving.

Teardrop roofs, mounting collars and edge chamfers or rounding change fit-critical or visible surfaces. They are therefore listed under **For your review** and never applied automatically. Ribs, gussets, splitting and the experimental treatments are also never automatic. Detection only recognises axis-aligned flat faces and round edges, so angled or freeform features are not treated. The 0.45 mm line width and 0.2 mm layer height are estimates, not Slant specifications. Test-print the copy before relying on it.
