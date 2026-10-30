import XCTest
import simd
@testable import Plinth

/// Round 4 review fixes in the Models, personalisation and listing area.
final class ModelsReviewFixesTests: XCTestCase {
    // MARK: Import Orders: personalised orders use the plain model

    private func product(_ name: String, sku: String) -> SavedProduct {
        var line = SavedProductLine()
        line.reference = "file-\(sku)"
        line.filamentID = "filament-1"
        line.name = name
        return SavedProduct(name: name, sku: sku, lines: [line])
    }

    private lazy var keychain = product("Keychain", sku: "KEY")

    private func context(choices: [String: OrderImportProductChoice] = [:]) -> OrderImportContext {
        var context = OrderImportContext(products: [keychain], platformID: "platform-1")
        context.productChoices = choices
        return context
    }

    private let personalised = """
    order_id,name,email,line1,line2,city,state,zip,country,sku,quantity,Personalisation
    A1,Ana,ana@example.com,1 Main St,,Austin,TX,78701,US,KEY,1,Zoë
    A2,Ben,ben@example.com,2 Main St,,Austin,TX,78701,US,KEY,1,
    A3,Cy,cy@example.com,3 Main St,,Austin,TX,78701,US,KEY,1,
    A3,Cy,cy@example.com,3 Main St,,Austin,TX,78701,US,,1,Happy birthday
    """

    /// Order A3: a keychain and a personalised gift note with no SKU (the template has no item-name column).
    private func orderWithGiftNote() throws -> OrderImportOrder {
        var order = try orderImportParse(data: Data(personalised.utf8)).orders[2]
        order.items[1].itemName = "Gift Note"
        return order
    }

    func testPersonalisedOrderIsFlaggedAndStartsUnticked() throws {
        let orders = try orderImportParse(data: Data(personalised.utf8)).orders
        XCTAssertEqual(orders.map(\.items.count), [1, 1, 2])
        let flagged = orderImportCheck(orders[0], context: context())
        XCTAssertEqual(flagged.warnings, [orderImportPlainModelWarning])
        XCTAssertEqual(orderImportPlainModelWarning, "This draft uses the plain model. Make the personalised one first.")
        XCTAssertFalse(flagged.tickedByDefault, "starts unticked, like other orders that need a second look")
        XCTAssertTrue(flagged.canTick, "the seller can still tick it deliberately")
        XCTAssertNotNil(flagged.body)
        XCTAssertFalse(String(describing: flagged.body ?? [:]).contains("Zoë"), "the draft never carries the personalisation")

        let plain = orderImportCheck(orders[1], context: context())
        XCTAssertTrue(plain.warnings.isEmpty)
        XCTAssertTrue(plain.tickedByDefault)
    }

    func testLeftOutPersonalisedItemIsNotFlagged() throws {
        let order = try orderWithGiftNote()
        let left = orderImportCheck(order, context: context(choices: ["name|gift note": .leaveOut]))
        XCTAssertFalse(left.warnings.contains(orderImportPlainModelWarning), "the personalised item isn't in the draft")
        XCTAssertTrue(left.tickedByDefault)
        let unmatched = orderImportCheck(order, context: context())
        XCTAssertTrue(unmatched.warnings.contains(orderImportPlainModelWarning))
        XCTAssertFalse(unmatched.canTick, "still blocked until the item is matched or left out")
    }

    func testChoiceThatUnblocksAPersonalisedOrderDoesNotTickIt() throws {
        let order = try orderWithGiftNote()
        let before = ["A3": orderImportCheck(order, context: context())]
        let after = ["A3": orderImportCheck(order, context: context(choices: ["name|gift note": .product(keychain.id)]))]
        XCTAssertTrue(after["A3"]?.canTick == true)
        XCTAssertTrue(orderImportNewlyTickable(before: before, after: after).isEmpty)
    }

    // MARK: Personalisation temp folders

    func testOnlyStudiosOwnTempFoldersAreRecognised() {
        let id = UUID().uuidString
        XCTAssertTrue(isPersonalisationTempFolderName("Plinth-OpenSCAD-\(id)"))
        XCTAssertTrue(isPersonalisationTempFolderName("Plinth-Personalised-\(id)"))
        XCTAssertFalse(isPersonalisationTempFolderName("Plinth-OpenSCAD-"))
        XCTAssertFalse(isPersonalisationTempFolderName("Plinth-OpenSCAD-\(id)-extra"))
        XCTAssertFalse(isPersonalisationTempFolderName("Plinth-OpenSCAD-notauuid"))
        XCTAssertFalse(isPersonalisationTempFolderName("Other-OpenSCAD-\(id)"))
        XCTAssertFalse(isPersonalisationTempFolderName(id))
        XCTAssertFalse(isPersonalisationTempFolderName("PlinthListing-\(id)"))
        XCTAssertFalse(isPersonalisationTempFolderName("Plinth-\(id)"))
        XCTAssertFalse(isPersonalisationTempFolderName("Plinth-Download-\(id)"), "a download is a file its caller removes")
        // Slant Studio's names are still recognised (only for clean-up), as strictly.
        XCTAssertTrue(isPersonalisationTempFolderName("SlantStudio-OpenSCAD-\(id)"))
        XCTAssertTrue(isPersonalisationTempFolderName("SlantStudio-Personalised-\(id)"))
        XCTAssertFalse(isPersonalisationTempFolderName("SlantStudio-OpenSCAD-"))
        XCTAssertFalse(isPersonalisationTempFolderName("SlantStudio-OpenSCAD-\(id)-extra"))
        XCTAssertFalse(isPersonalisationTempFolderName("SlantStudioListing-\(id)"))
        XCTAssertFalse(isPersonalisationTempFolderName("SlantStudio-OpenSCAD-notauuid"))
    }

    func testStaleFoldersRespectAnotherRunningCopy() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = "Plinth-OpenSCAD-\(UUID().uuidString)"
        let fresh = "Plinth-Personalised-\(UUID().uuidString)"
        let undated = "SlantStudio-OpenSCAD-\(UUID().uuidString)"
        let entries: [(name: String, created: Date?)] = [
            (old, now.addingTimeInterval(-601)), (fresh, now.addingTimeInterval(-30)), (undated, nil), ("unrelated", nil)
        ]
        XCTAssertEqual(Set(stalePersonalisationTempFolderNames(entries, now: now, otherInstanceMayBeRunning: false)),
                       [old, fresh, undated], "alone, every leftover of ours goes")
        XCTAssertEqual(stalePersonalisationTempFolderNames(entries, now: now, otherInstanceMayBeRunning: true), [old],
                       "another copy's run in progress is left alone")
        XCTAssertTrue(stalePersonalisationTempFolderNames([], now: now, otherInstanceMayBeRunning: false).isEmpty)
    }

    func testLocalRunIsRegisteredWhileRunningAndStopAllEndsIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ModelsReviewFixes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let slow = folder.appendingPathComponent("fake-openscad")
        try "#!/bin/sh\nexec sleep 30\n".write(to: slow, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slow.path)
        let template = folder.appendingPathComponent("t.scad")
        let before = OpenSCADRunRegistry.shared.count
        let task = Task { try await runOpenSCADProcess(executable: slow, templateURL: template, assignments: []) }
        var waited = 0
        while OpenSCADRunRegistry.shared.count == before, waited < 50 {
            try await Task.sleep(nanoseconds: 50_000_000); waited += 1
        }
        XCTAssertEqual(OpenSCADRunRegistry.shared.count, before + 1)
        let started = Date()
        OpenSCADRunRegistry.shared.stopAll()
        XCTAssertEqual(OpenSCADRunRegistry.shared.count, 0)
        do {
            _ = try await task.value
            XCTFail("a stopped run must not return a model")
        } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(OpenSCADRunRegistry.shared.count, 0)
    }

    // MARK: Slant generation errors in Activity

    func testActivityRecordsOnlyTheStatusForSlantGenerations() {
        let quoted = APIError.http(status: 422, body: #"{"message":"Parser error near \"Emma Rose\""}"#, retryAfter: nil, rateLimitReset: nil)
        let detail = openSCADActivityDetail(for: quoted)
        XCTAssertEqual(detail, "Slant didn’t generate the model (HTTP 422)")
        XCTAssertFalse(detail.contains("Emma"))
        XCTAssertTrue(friendlyAPIMessage(quoted).contains("Emma"), "the sheet may still show Slant's text")
        XCTAssertFalse(activityDetail(for: StudioError(detail)).contains("Emma"))
        XCTAssertEqual(openSCADActivityDetail(for: APIError.http(status: 429, body: "Emma", retryAfter: "60", rateLimitReset: nil)),
                       "Slant’s OpenSCAD limit was reached (HTTP 429)")
        XCTAssertEqual(openSCADActivityDetail(for: URLError(.timedOut)), "Slant couldn’t be reached, or didn’t reply in time")
        XCTAssertEqual(openSCADActivityDetail(for: APIError.invalidResponse("Emma")), "The generation didn’t complete")
        XCTAssertEqual(openSCADActivityDetail(for: StudioError("Emma")), "The generation didn’t complete")
    }

    // MARK: Personalise sheet

    func testPrivacyNoteSaysWhatLeavesTheSheet() {
        XCTAssertEqual(personalisationPrivacyNote,
                       "Values aren’t kept in Plinth, but the new model’s name and STL include them. With Slant’s generator, the template and values are sent to Slant.")
    }

    func testQuotaRefreshWakesJustAfterTheNextGeneration() {
        let now = Date(timeIntervalSince1970: 5_000)
        XCTAssertEqual(personalisationQuotaRefreshDelay(nextAvailable: nil, now: now), 30)
        XCTAssertEqual(personalisationQuotaRefreshDelay(nextAvailable: now.addingTimeInterval(10), now: now), 10.5)
        XCTAssertEqual(personalisationQuotaRefreshDelay(nextAvailable: now.addingTimeInterval(3_000), now: now), 30)
        XCTAssertEqual(personalisationQuotaRefreshDelay(nextAvailable: now.addingTimeInterval(-5), now: now), 1)

        // Five sends a minute apart: blocked until an hour after the first, and the sheet wakes just after that.
        var quota = OpenSCADQuota()
        for minute in 0..<5 { XCTAssertTrue(quota.begin(now: now.addingTimeInterval(Double(minute) * 60))); quota.finish() }
        let nearReset = now.addingTimeInterval(3_590)
        XCTAssertNotNil(quota.blockedReason(now: nearReset))
        XCTAssertEqual(personalisationQuotaRefreshDelay(nextAvailable: quota.nextAvailable(now: nearReset), now: nearReset), 10.5)
        XCTAssertNil(quota.blockedReason(now: nearReset.addingTimeInterval(10.5)), "Generate STL is available at the wake-up")
    }

    // MARK: Listing details

    func testListingMaterialOnlyForTheSelectedModel() {
        let selected = UUID(), other = UUID()
        XCTAssertEqual(listingDetailsMaterialName(modelID: selected, selectedModelID: selected, selectedMaterialName: "PLA MATTE BLACK"),
                       "PLA Matte Black")
        XCTAssertNil(listingDetailsMaterialName(modelID: other, selectedModelID: selected, selectedMaterialName: "PLA MATTE BLACK"))
        XCTAssertNil(listingDetailsMaterialName(modelID: other, selectedModelID: nil, selectedMaterialName: "PLA MATTE BLACK"))
        XCTAssertNil(listingDetailsMaterialName(modelID: selected, selectedModelID: selected, selectedMaterialName: "  "))
        XCTAssertNil(listingDetailsMaterialName(modelID: selected, selectedModelID: selected, selectedMaterialName: nil))
    }

    func testCopiedTextLeavesTheInstructionToTheConfirmation() {
        let text = listingDetailsText(ListingDetailsFacts(extentMM: SIMD3(10, 10, 10), materialName: "PLA Matte Black"))
        XCTAssertFalse(text.contains(listingProductionPartnerNote))
        XCTAssertFalse(text.contains("Suggested wording"))
        XCTAssertTrue(text.hasSuffix(listingProductionPartnerSuggestion + "\n"))
        for message in [listingDetailsCopiedMessage(hasSize: true, scaleSuspect: false),
                        listingDetailsCopiedMessage(hasSize: true, scaleSuspect: true),
                        listingDetailsCopiedMessage(hasSize: false, scaleSuspect: false)] {
            XCTAssertTrue(message.hasSuffix(listingProductionPartnerNote))
            XCTAssertGreaterThan(listingNoticeDuration(message), 3, "long enough to read")
        }
        XCTAssertEqual(listingNoticeDuration("Copied."), 3)
        XCTAssertEqual(listingNoticeDuration(String(repeating: "a", count: 1_000)), 12)
    }

    // MARK: Renderer cancellation

    /// A box `x` wide, `y` deep and `z` tall, from the origin.
    private func box(_ x: Float, _ y: Float, _ z: Float) -> STLMesh {
        let p: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(x, 0, 0), SIMD3(x, y, 0), SIMD3(0, y, 0),
            SIMD3(0, 0, z), SIMD3(x, 0, z), SIMD3(x, y, z), SIMD3(0, y, z)
        ]
        let faces: [(Int, Int, Int)] = [
            (0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7), (0, 1, 5), (0, 5, 4),
            (1, 2, 6), (1, 6, 5), (2, 3, 7), (2, 7, 6), (3, 0, 4), (3, 4, 7)
        ]
        let vertices = faces.flatMap { [p[$0.0], p[$0.1], p[$0.2]] }.flatMap { [$0.x, $0.y, $0.z] }
        return STLMesh(vertices: vertices, minimum: .zero, maximum: SIMD3(x, y, z))
    }

    private func fnv1a(_ bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return hash
    }

    /// Fingerprints of the renderer's output before the in-triangle cancellation checks were added: they must match.
    func testRendererOutputIsUnchanged() throws {
        let thumbnail = try XCTUnwrap(renderThumbnailRGBA(box(20, 10, 5), size: 96))
        let listing = try XCTUnwrap(renderMeshRGBA(box(30, 12, 18), size: 300, camera: listingCamera(.rearThreeQuarter),
                                                   style: listingRenderStyle(colour: SIMD3(0.1, 0.4, 0.8), camera: listingCamera(.rearThreeQuarter)),
                                                   rasterBudget: listingImageRasterBudget))
        XCTAssertEqual(fnv1a(thumbnail), 11_276_435_669_170_151_699, "thumbnail")
        XCTAssertEqual(fnv1a(listing), 12_334_878_132_213_487_370, "listing")
    }

    func testCancellationIsCheckedInsideALargeTriangle() {
        // 12 triangles at 2000 px (4000 × 4000 samples): the per-triangle check alone would only run once.
        var calls = 0
        let result = renderMeshRGBA(box(20, 20, 20), size: 2000, camera: listingCamera(.front),
                                    style: listingRenderStyle(colour: listingNeutralColour, camera: listingCamera(.front)),
                                    rasterBudget: listingImageRasterBudget, isCancelled: { calls += 1; return calls > 3 })
        XCTAssertTrue(result == nil, "cancelled")
        XCTAssertEqual(calls, 4, "stopped at the first in-raster check after cancellation")
    }
}
