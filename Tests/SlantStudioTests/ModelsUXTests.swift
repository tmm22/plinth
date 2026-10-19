import XCTest
@testable import SlantStudio

final class ModelsUXTests: XCTestCase {
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
        XCTAssertEqual(rows.map(\.0), [
            "Price per unit", "Quantity", "Subtotal", "Material", "Print time", "Multi-part charge", "Oversize fee", "Total"
        ])
        XCTAssertEqual(rows.map(\.1), ["$4.06", "3", "$12.18", "PLA Black", "42 min", "$1.50", "$0.25", "$13.93"])
        let displayed = displayedEstimateRows(estimate)
        XCTAssertFalse(displayed.map(\.0).contains("Total"))
        XCTAssertFalse(displayed.map(\.0).contains("Quantity"))
        XCTAssertTrue(displayed.map(\.0).contains("Subtotal"))
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
        XCTAssertEqual(rows["Dimensions"], "10x20x5 mm")
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
        XCTAssertEqual(importFromURLValidation(url: "http://example.com/a.stl", name: "Part"), "Use an https:// link to import a model.")
        XCTAssertEqual(importFromURLValidation(url: "https://example.com/a.stl", name: "  "), "Enter a name for the imported model.")
        XCTAssertNil(importFromURLValidation(url: "https://example.com/a.stl", name: "Bracket"))
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
