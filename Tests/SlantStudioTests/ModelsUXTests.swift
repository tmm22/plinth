import XCTest
@testable import SlantStudio

final class ModelsUXTests: XCTestCase {
    func testQuantityEditingNeverSilentlyChangesInvalidInputIntoAnOrderQuantity() {
        XCTAssertEqual(printQuantity("1"), 1)
        XCTAssertEqual(printQuantity("10000"), 10000)
        XCTAssertEqual(printQuantity("25"), 25)
        for input in ["", "0", "10001", "-2", "1.5", "1e2", "2 parts", "999999999999999999999999"] {
            XCTAssertNil(printQuantity(input), input)
        }
    }

    func testEstimateRowsExtractLabeledFieldsWithoutJSONDump() {
        let estimate: [String: Any] = [
            "pricePerUnit": "4.06",
            "quantity": 3,
            "subtotal": "12.18",
            "totalMaterial": "PLA Black",
            "estimatedPrintTime": 42,
            "bodyChargeCost": "1.50",
            "oversizeSurcharge": "0.25",
            "total": "13.93",
            "rawNoise": ["nested": true]
        ]
        let rows = estimateRows(estimate)
        // Print time and material have no documented unit, and the subtotal contradicted the per-unit price live.
        XCTAssertEqual(rows.map(\.0), ["Price per unit", "Quantity", "Charge for extra bodies", "Oversize fee", "Total"])
        XCTAssertEqual(rows.map(\.1), ["$4.06", "3", "$1.50", "$0.25", "$13.93"])
        let displayed = displayedEstimateRows(estimate)
        XCTAssertEqual(displayed.map(\.0), ["Price per unit", "Charge for extra bodies", "Oversize fee"])
        XCTAssertFalse(displayed.contains { $0.1.contains("min") })
    }

    func testEstimateRowsListOnlyChargedSurcharges() {
        // Live reply shape from 23 Oct 2026: numbers, both surcharges zero.
        let live: [String: Any] = ["pricePerUnit": 9.93, "quantity": 1, "subtotal": 7.64, "total": 9.93,
                                   "totalMaterial": 101.88, "estimatedPrintTime": 6.66,
                                   "bodyChargeCost": 0, "oversizeSurcharge": 0.0]
        XCTAssertEqual(displayedEstimateRows(live).map(\.0), ["Price per unit"])
        XCTAssertEqual(displayedEstimateRows(live).map(\.1), ["$9.93"])
        XCTAssertEqual(displayedEstimateRows(["bodyChargeCost": "2.00", "oversizeSurcharge": NSNull()]).map(\.0), ["Charge for extra bodies"])
        XCTAssertTrue(estimateAmountIsCharged("abc"), "an unreadable amount is shown as — rather than hidden")
        XCTAssertFalse(estimateAmountIsCharged(nil))
        XCTAssertFalse(estimateAmountIsCharged("0.00"))
        XCTAssertFalse(estimateAmountIsCharged(-1))
    }

    func testBodyChargeIsNamedWithSlantsBodyCountForTheEstimatedFile() {
        let estimate: [String: Any] = ["pricePerUnit": 6.95, "quantity": 1, "bodyChargeCost": 3.5, "total": 6.95]
        // The live test's ten-body block: nine extra bodies.
        XCTAssertEqual(displayedEstimateRows(estimate, bodyCount: 10).map(\.0), ["Price per unit", "Charge for 9 extra bodies"])
        XCTAssertEqual(displayedEstimateRows(estimate, bodyCount: 10).map(\.1), ["$6.95", "$3.50"])
        XCTAssertEqual(estimateBodyChargeLabel(bodyCount: 2), "Charge for 1 extra body")
        XCTAssertEqual(estimateBodyChargeLabel(bodyCount: 1), "Charge for extra bodies")
        XCTAssertEqual(estimateBodyChargeLabel(bodyCount: nil), "Charge for extra bodies")
        // No charge, no row, whatever the count.
        XCTAssertEqual(displayedEstimateRows(["bodyChargeCost": 0], bodyCount: 10).map(\.0), [])

        let file = Record(values: ["publicFileServiceId": "file-a", "metrics": ["bodyCount": 10]])
        XCTAssertEqual(estimateBodyCount(estimateContext: "file-a|pla|1", file: file), 10)
        // A previous file's estimate never borrows another file's count.
        XCTAssertNil(estimateBodyCount(estimateContext: "file-b|pla|1", file: file))
        XCTAssertNil(estimateBodyCount(estimateContext: "", file: file))
        XCTAssertNil(estimateBodyCount(estimateContext: "file-a|pla|1", file: nil))
        XCTAssertEqual(slantBodyCount(["bodyCount": "3"]), 3)
        for unreadable: Any in [2.5, 0, -1, "many", NSNull(), true, Double.nan] {
            XCTAssertNil(slantBodyCount(["bodyCount": unreadable]), "\(unreadable)")
        }
        XCTAssertNil(slantBodyCount([:]))
        XCTAssertEqual(metricName("bodyCount"), "Bodies")
    }

    func testEstimateRowsOmitMissingKeys() {
        XCTAssertEqual(estimateRows(["total": "9.00"]).map(\.0), ["Total"])
        XCTAssertTrue(estimateRows([:]).isEmpty)
    }

    func testEstimateDisabledReasonsRequireMaterialAndStock() {
        XCTAssertEqual(estimateDisabledReason(hasKey: false, fileID: "", filamentID: "", busy: false), "Connect your account first")
        XCTAssertEqual(estimateDisabledReason(hasKey: true, fileID: "", filamentID: "", busy: false), "Upload this model first")
        XCTAssertEqual(estimateDisabledReason(hasKey: true, fileID: "file-1", filamentID: "", busy: false), "Choose a material")
        XCTAssertEqual(estimateDisabledReason(hasKey: true, fileID: "file-1", filamentID: "filament-1", busy: false, materialAvailable: false), "This material is out of stock")
        XCTAssertNil(estimateDisabledReason(hasKey: true, fileID: "file-1", filamentID: "filament-1", busy: false))
        XCTAssertNil(estimateDisabledReason(hasKey: false, fileID: "", filamentID: "", busy: true))
    }

    func testUploadDisabledReasonUsesPlainLanguageHint() {
        XCTAssertEqual(uploadDisabledReason(hasKey: false, platformID: ""), "Connect your Slant account and choose a platform to upload.")
        XCTAssertEqual(uploadDisabledReason(hasKey: true, platformID: ""), "Connect your Slant account and choose a platform to upload.")
        XCTAssertNil(uploadDisabledReason(hasKey: true, platformID: "platform-1"))
        XCTAssertFalse(uploadDisabledReason(hasKey: false, platformID: "")!.localizedCaseInsensitiveContains("api"))
    }

    func testUploadStageProgressRecognizesUploadTitleAndAPIClientStages() {
        XCTAssertTrue(isUploadStageProgress("Upload Bracket"))
        XCTAssertTrue(isUploadStageProgress("Preparing upload…"))
        XCTAssertTrue(isUploadStageProgress("Requesting upload URL…"))
        XCTAssertTrue(isUploadStageProgress("Uploading model…"))
        XCTAssertTrue(isUploadStageProgress("Confirming upload and processing model…"))
        XCTAssertFalse(isUploadStageProgress("Estimate print cost"))
    }

    func testOrderDraftDisabledReasonForStaleEstimateMissingMaterialAndStock() {
        XCTAssertEqual(orderDraftDisabledReason(estimateIsCurrent: true, filamentID: "", busy: false), "Choose a material")
        XCTAssertEqual(orderDraftDisabledReason(estimateIsCurrent: true, filamentID: "filament-1", busy: false, materialAvailable: false), "This material is out of stock")
        XCTAssertEqual(orderDraftDisabledReason(estimateIsCurrent: false, filamentID: "filament-1", busy: false), "Configuration changed · request a new estimate")
        XCTAssertNil(orderDraftDisabledReason(estimateIsCurrent: true, filamentID: "filament-1", busy: false))
    }

    func testDisplayNameFallsBackWithoutUsingRawIds() {
        let named = Record(values: ["name": "PLA Black", "publicId": "filament-uuid"])
        let nameless = Record(values: ["publicId": "filament-uuid-only"])
        XCTAssertEqual(displayName(for: named, fallback: "Untitled material"), "PLA Black")
        XCTAssertEqual(displayName(for: nameless, fallback: "Untitled material"), "Untitled material")
        XCTAssertEqual(cloudModelDisplayName(nameless), "Untitled model")
    }

    func testCatalogSearchMatchesNameAndDescriptionNotRawJSONKeys() {
        let record = Record(values: [
            "name": "Matte PLA",
            "description": "Smooth finish filament",
            "webhookSecret": "should-not-match-search",
            "publicId": "filament-json-key-noise"
        ])
        XCTAssertTrue(catalogRecordMatches(record, search: "matte"))
        XCTAssertTrue(catalogRecordMatches(record, search: "smooth finish"))
        XCTAssertFalse(catalogRecordMatches(record, search: "webhookSecret"))
        XCTAssertFalse(catalogRecordMatches(record, search: "should-not-match-search"))
    }

    func testCloudFilesMatchingFiltersByDisplayNameNotRawId() {
        let files = [
            Record(values: ["name": "Bracket", "publicFileServiceId": "a"]),
            Record(values: ["publicFileServiceId": "secret-uuid-token"])
        ]
        XCTAssertEqual(cloudFilesMatching(files, search: "brac").map(cloudModelDisplayName), ["Bracket"])
        XCTAssertTrue(cloudFilesMatching(files, search: "secret-uuid-token").isEmpty)
    }

    func testIndexedRecordsStabilizesEmptyAndDuplicateIds() {
        let records = [
            Record(values: ["name": "A"]),
            Record(values: ["name": "B", "publicId": "dup"]),
            Record(values: ["name": "C", "publicId": "dup"])
        ]
        let rows = indexedRecords(records)
        XCTAssertEqual(Set(rows.map(\.id)).count, 3)
    }

    func testHidingSecretsRedactsSecretKeys() {
        let redacted = hidingSecrets(["name": "Shop", "webhookSecret": "abc", "nested": ["apiSecret": "xyz"]]) as? [String: Any]
        XCTAssertEqual(redacted?["webhookSecret"] as? String, "Hidden")
        XCTAssertEqual((redacted?["nested"] as? [String: Any])?["apiSecret"] as? String, "Hidden")
    }

    func testMetricDisplaySkipsNullValuesAndDetectsPendingAnalysis() {
        XCTAssertNil(metricDisplayValue(NSNull()))
        XCTAssertNil(metricDisplayValue(nil))
        XCTAssertEqual(metricDisplayValue(12.5), "12.5")
        let pending: [String: Any] = ["x": NSNull(), "y": NSNull(), "weight": NSNull()]
        XCTAssertTrue(metricsAwaitingAnalysis(pending))
        XCTAssertTrue(usableMetricEntries(pending).isEmpty)
        let ready: [String: Any] = ["x": 20, "y": 10, "z": 5]
        XCTAssertFalse(metricsAwaitingAnalysis(ready))
        XCTAssertEqual(usableMetricEntries(ready).map(\.0), ["x", "y", "z"])
    }

    func testWeightUnitAndNestedMetricsImageSupport() {
        let withUnit = usableMetricEntries(["weight": 12, "weightUnit": "kg"])
        XCTAssertEqual(withUnit.first?.2, "12 kg")
        let defaultGrams = usableMetricEntries(["weight": 8])
        XCTAssertEqual(defaultGrams.first?.2, "8 g")

        let nested = Record(values: [
            "metrics": [
                "supportRequired": true,
                "imageURL": "https://cdn.example.com/preview.png"
            ]
        ])
        XCTAssertEqual(supportRequiredCaption(nested), "Needs supports · Yes")
        XCTAssertNotNil(httpsPreviewImageURL(nested))

        let topLevel = Record(values: [
            "supportRequired": false,
            "imageURL": "https://cdn.example.com/top.png"
        ])
        XCTAssertEqual(supportRequiredCaption(topLevel), "Needs supports · No")
        XCTAssertNotNil(httpsPreviewImageURL(topLevel))
        XCTAssertNil(httpsPreviewImageURL(Record(values: ["imageURL": "http://insecure.example.com/preview.png"])))
    }

    func testSupportRequiredAndHTTPSPreviewHelpers() {
        XCTAssertEqual(supportRequiredCaption(Record(values: ["supportRequired": true])), "Needs supports · Yes")
        XCTAssertEqual(supportRequiredCaption(Record(values: ["supportRequired": false])), "Needs supports · No")
        XCTAssertNil(supportRequiredCaption(Record(values: ["supportRequired": NSNull()])))
        XCTAssertNotNil(httpsPreviewImageURL(Record(values: ["imageURL": "https://cdn.example.com/preview.png"])))
        XCTAssertNil(httpsPreviewImageURL(Record(values: ["imageURL": "http://insecure.example.com/preview.png"])))
    }

    func testComponentFactRowsAndCategoryLabel() {
        let record = Record(values: [
            "price": "4.50",
            "priceUnit": "each",
            "dimensions": "10x20x5",
            "dimensionUnit": "mm",
            "weight": "12g",
            "tags": ["hinge", "metal"],
            "category": "Hardware"
        ])
        let rows = Dictionary(uniqueKeysWithValues: componentFactRows(record))
        XCTAssertEqual(rows["Price"], "$4.50 / each")
        XCTAssertEqual(rows["Dimensions"], "10x20x5", "never with dimensionUnit added: live sends \"mm\" on inch rows too")
        XCTAssertEqual(rows["Weight"], "12g")
        XCTAssertEqual(rows["Tags"], "hinge, metal")
        XCTAssertEqual(componentCategoryLabel(record), "Hardware")

        let categories = [
            Record(values: ["publicId": "parent", "name": "Parts"]),
            Record(values: ["publicId": "cat-1", "name": "Hinges", "parentId": "parent"])
        ]
        XCTAssertEqual(
            componentCategoryLabel(Record(values: ["categoryId": "cat-1"]), categories: categories),
            "Parts › Hinges"
        )
        XCTAssertNil(componentCategoryLabel(Record(values: ["categoryId": "missing"]), categories: categories))
    }

    func testImportFromURLValidation() {
        XCTAssertEqual(importFromURLValidation(url: "http://example.com/a.stl", name: "Part"), "Use an https:// link to upload a model.")
        XCTAssertEqual(importFromURLValidation(url: "https://example.com/a.stl", name: "  "), "Enter a name for the uploaded model.")
        XCTAssertNil(importFromURLValidation(url: "https://example.com/a.stl", name: "Bracket"))
    }

    func testNextStepBarHiddenOnlyForEmptyImportOrConnectStates() {
        // The empty inspector already says "Import your first model" / "Connect Slant Account…".
        XCTAssertFalse(showsModelsNextStepBar(hasSelection: false, step: .needsModel))
        XCTAssertFalse(showsModelsNextStepBar(hasSelection: false, step: .needsSetup))
        // Platform setup and an upload of another model still need the bar.
        XCTAssertTrue(showsModelsNextStepBar(hasSelection: false, step: .needsPlatform))
        XCTAssertTrue(showsModelsNextStepBar(hasSelection: false, step: .uploading))
        XCTAssertTrue(showsModelsNextStepBar(hasSelection: true, step: .needsSetup))
        XCTAssertTrue(showsModelsNextStepBar(hasSelection: true, step: .readyForDraft))
    }

    func testModelsNextStepProgression() {
        XCTAssertEqual(
            modelsNextStep(hasKey: false, platformID: "", hasSelection: false, hasLocalNeedingUpload: false, fileID: "", filamentID: "", hasEstimate: false, estimateIsCurrent: false, isUploading: false),
            .needsSetup
        )
        XCTAssertEqual(
            modelsNextStep(hasKey: true, platformID: "", hasSelection: false, hasLocalNeedingUpload: false, fileID: "", filamentID: "", hasEstimate: false, estimateIsCurrent: false, isUploading: false),
            .needsPlatform
        )
        XCTAssertEqual(
            modelsNextStep(hasKey: true, platformID: "p", hasSelection: false, hasLocalNeedingUpload: false, fileID: "", filamentID: "", hasEstimate: false, estimateIsCurrent: false, isUploading: false),
            .needsModel
        )
        XCTAssertEqual(
            modelsNextStep(hasKey: true, platformID: "p", hasSelection: true, hasLocalNeedingUpload: false, fileID: "", filamentID: "", hasEstimate: false, estimateIsCurrent: false, isUploading: true),
            .uploading
        )
        XCTAssertEqual(
            modelsNextStep(hasKey: true, platformID: "p", hasSelection: true, hasLocalNeedingUpload: true, fileID: "", filamentID: "", hasEstimate: false, estimateIsCurrent: false, isUploading: false),
            .needsUpload
        )
        XCTAssertEqual(
            modelsNextStep(hasKey: true, platformID: "p", hasSelection: true, hasLocalNeedingUpload: false, fileID: "f", filamentID: "", hasEstimate: false, estimateIsCurrent: false, isUploading: false),
            .needsEstimate
        )
        XCTAssertEqual(
            modelsNextStep(hasKey: true, platformID: "p", hasSelection: true, hasLocalNeedingUpload: false, fileID: "f", filamentID: "m", hasEstimate: true, estimateIsCurrent: false, isUploading: false),
            .estimateStale
        )
        XCTAssertEqual(
            modelsNextStep(hasKey: true, platformID: "p", hasSelection: true, hasLocalNeedingUpload: false, fileID: "f", filamentID: "m", hasEstimate: true, estimateIsCurrent: true, isUploading: false),
            .readyForDraft
        )
    }

    func testLibrarySelectionMapping() {
        let localID = UUID()
        XCTAssertEqual(librarySelection(selectedLocalID: localID, fileID: "cloud"), .local(localID))
        XCTAssertEqual(librarySelection(selectedLocalID: nil, fileID: "cloud-1"), .cloud("cloud-1"))
        XCTAssertNil(librarySelection(selectedLocalID: nil, fileID: ""))
    }

    func testWebhookRotateTypedConfirm() {
        XCTAssertTrue(webhookRotateTypedConfirmAllowed("rotate"))
        XCTAssertTrue(webhookRotateTypedConfirmAllowed(" ROTATE "))
        XCTAssertFalse(webhookRotateTypedConfirmAllowed("rot"))
        XCTAssertFalse(webhookRotateTypedConfirmAllowed(""))
    }

    func testCloudDownloadExtensionPrefersTypeThenURL() {
        XCTAssertEqual(cloudDownloadExtension(recordType: "obj", downloadURL: URL(string: "https://cdn.example.com/a.stl")!), "obj")
        XCTAssertEqual(cloudDownloadExtension(recordType: nil, downloadURL: URL(string: "https://cdn.example.com/part.3mf")!), "3mf")
        XCTAssertEqual(cloudDownloadExtension(recordType: "bin", downloadURL: URL(string: "https://cdn.example.com/part")!), "stl")
    }

    func testWebhookResultMessages() {
        XCTAssertEqual(
            webhookTestResultMessage(WebhookTestResult(attempted: true, endpointStatus: 200, message: nil)),
            "Slant attempted delivery; your endpoint returned HTTP 200"
        )
        XCTAssertEqual(
            webhookTestResultMessage(WebhookTestResult(attempted: true, endpointStatus: 500, message: nil)),
            "Slant attempted delivery; your endpoint returned HTTP 500"
        )
        XCTAssertEqual(
            webhookResendResultMessage(WebhookResendResult(attempted: 25, delivered: 2, failed: 1, expired: 0, remaining: 3)),
            "Attempted 25 · delivered 2 · failed 1 · expired 0 · remaining 3"
        )
    }

    func testDisplayedWebhookSecretPrefersRotated() {
        XCTAssertEqual(displayedWebhookSecret(rotatedSecret: "new-secret", currentSecret: "old-secret"), "new-secret")
        XCTAssertEqual(displayedWebhookSecret(rotatedSecret: nil, currentSecret: "old-secret"), "old-secret")
        XCTAssertEqual(displayedWebhookSecret(rotatedSecret: nil, currentSecret: ""), "")
    }
}

final class ModelsSimplificationTests: XCTestCase {
    func testPlatformSetupCreatesOnlyWhenTheLoadedAccountHasNone() {
        XCTAssertEqual(platformSetupAction(platformsLoaded: true, platformCount: 0), .createPlatform)
        XCTAssertEqual(platformSetupAction(platformsLoaded: true, platformCount: 2), .chooseInSettings)
        // Unknown until platforms load: Settings can load them, so never assume the account has none.
        XCTAssertEqual(platformSetupAction(platformsLoaded: false, platformCount: 0), .chooseInSettings)
        XCTAssertTrue(platformSetupStatus(.createPlatform).hasSuffix("."))
        XCTAssertTrue(platformSetupStatus(.chooseInSettings).contains("Settings"))
    }

    func testMaterialPickerGroupsByTypeKeepingEveryMaterialAndItsOrder() {
        let filaments = [
            Record(values: ["publicId": "1", "name": "PLA Black", "profile": "PLA"]),
            Record(values: ["publicId": "2", "name": "PETG Clear", "profile": "PETG", "available": false]),
            Record(values: ["publicId": "3", "name": "PLA White", "profile": "pla "]),
            Record(values: ["publicId": "4", "name": "Mystery", "profile": ""])
        ]
        let sections = materialPickerSections(filaments)
        XCTAssertEqual(sections.map(\.type), ["PETG", "PLA", "Other"])
        XCTAssertEqual(sections.map { $0.materials.map(\.id) }, [["2"], ["1", "3"], ["4"]])
        XCTAssertEqual(Set(sections.flatMap { $0.materials.map(\.id) }), Set(filaments.map(\.id)))
        // Out-of-stock materials stay listed, labelled as before.
        XCTAssertEqual(filamentPickerLabel(sections[0].materials[0]), "PETG Clear · Out of stock")
        XCTAssertTrue(materialPickerSections([]).isEmpty)
    }

    func testAutoImproveSummarySaysWhatToDoFirst() {
        var intent = PartIntent()
        XCTAssertTrue(autoImproveSummary(intent: intent, hasRecipe: false, improved: false).hasPrefix("One click"))
        intent.purpose = .bracket
        XCTAssertEqual(autoImproveSummary(intent: intent, hasRecipe: false, improved: false),
                       "First choose the main stress direction in Optimise for purpose.")
        // A prepared copy keeps its placement, so it doesn't need a direction.
        XCTAssertTrue(autoImproveSummary(intent: intent, hasRecipe: true, improved: false).hasPrefix("One click"))
        intent.load = .x
        XCTAssertTrue(autoImproveSummary(intent: intent, hasRecipe: false, improved: false).hasPrefix("One click"))
        intent.purpose = .custom
        XCTAssertEqual(autoImproveSummary(intent: intent, hasRecipe: false, improved: false),
                       "First describe the part in Optimise for purpose.")
        intent.load = .unknown
        XCTAssertEqual(autoImproveSummary(intent: intent, hasRecipe: false, improved: false),
                       "First describe the part and choose its main stress direction in Optimise for purpose.")
        XCTAssertEqual(autoImproveSummary(intent: intent, hasRecipe: false, improved: true), "Auto-improved copy · Original preserved")
    }

    func testEdgeImprovementIsOfferedOnlyForPlainBoxesLargeEnoughToEdit() {
        let box = EdgeDesignCheck(plainBox: true, hasSharpJoins: true, hasTransitions: false, complete: true)
        let detailed = EdgeDesignCheck(plainBox: false, hasSharpJoins: true, hasTransitions: true, complete: true)
        XCTAssertTrue(edgeImprovementAvailable(box, extent: SIMD3(10, 10, 10)))
        XCTAssertTrue(edgeImprovementAvailable(box, extent: SIMD3(10, 0.4, 10)))
        XCTAssertFalse(edgeImprovementAvailable(box, extent: SIMD3(10, 0.39, 10)))
        XCTAssertFalse(edgeImprovementAvailable(detailed, extent: SIMD3(10, 10, 10)))
    }
}
