import XCTest
@testable import SlantStudio

/// Round 16: Slant's order status can lag its own shipping record (29 Oct 2026: PRINTING with `fulfillment.status`
/// SHIPPED, tracking and a printed label). Studio shows the record's word and drops read-only alarms, and the cancel
/// re-check stops when the record changes; nothing here may ever enable a write.
final class ShippingRecordDisplayTests: XCTestCase {
    private func order(_ status: String = "PRINTING", fulfillment: Any? = nil, id: String = "SLANT_1") -> [String: Any] {
        var order: [String: Any] = [
            "publicId": id, "status": status, "createdAt": "2026-01-05T10:00:00Z",
            "processedAt": "2026-01-05T10:01:00Z", "printingCost": "10.00", "deliveryCost": "20.00",
            "items": [["type": "PRINT", "price": "10.00", "currency": "USD", "quantity": 1]]
        ]
        if let fulfillment { order["fulfillment"] = fulfillment }
        return order
    }
    private let shipped: [String: Any] = [
        "status": "SHIPPED", "provider": "SHIPPO", "deliveryMethod": "INTERNATIONAL", "trackingNumbers": ["TEST0001US"],
        "deliveryInstructions": NSNull(), "providerStatus": NSNull(), "labelPrinted": true
    ]

    // MARK: What the seller sees

    func testTheNoteNamesBothWordsWithoutClaimingHandover() {
        XCTAssertEqual(orderStatusLagNote(order(fulfillment: shipped)),
                       "Slant’s shipping record says Shipped, but Slant hasn’t yet updated this order’s status from Printing.")
        // A DELIVERED record (never seen live) reads as Shipped too.
        XCTAssertEqual(orderStatusLagNote(order("submitted", fulfillment: ["status": "delivered"])),
                       "Slant’s shipping record says Shipped, but Slant hasn’t yet updated this order’s status from Submitted.")
        XCTAssertNil(orderStatusLagNote(order(fulfillment: NSNull())))
        XCTAssertNil(orderStatusLagNote(order("SHIPPED", fulfillment: shipped)))
        let note = orderStatusLagNote(order(fulfillment: shipped)) ?? ""
        XCTAssertFalse(note.lowercased().contains("carrier"))
        XCTAssertFalse(note.contains("Canceled"))
    }

    func testTrackingForYourShopShowsTheShippingRecordsWord() throws {
        let entry = try XCTUnwrap(shopFollowUpEntry(Record(values: order(fulfillment: shipped))))
        XCTAssertEqual(entry.status, "PRINTING", "Slant's own status is kept")
        XCTAssertEqual(entry.displayStatus, "SHIPPED")
        let plain = try XCTUnwrap(shopFollowUpEntry(Record(values: order(fulfillment: ["trackingNumbers": ["1Z"]]))))
        XCTAssertEqual(plain.displayStatus, "PRINTING")
    }

    /// Sorting is local and display-only, so the Status column sorts by the word it shows.
    func testStatusColumnSortsByTheShownWord() {
        let lagging = OrderTableRow(record: Record(values: order(fulfillment: shipped, id: "A")))
        let printing = OrderTableRow(record: Record(values: order(id: "B")))
        let shippedRow = OrderTableRow(record: Record(values: order("SHIPPED", id: "C")))
        let delivered = OrderTableRow(record: Record(values: order(fulfillment: ["status": "DELIVERED"], id: "D")))
        XCTAssertEqual(lagging.status, "Shipped")
        XCTAssertEqual(delivered.status, "Shipped")
        XCTAssertNotNil(lagging.statusNote)
        XCTAssertNil(printing.statusNote)
        XCTAssertNil(shippedRow.statusNote)
        let sorted = orderTableRowsSorted([shippedRow, lagging, printing, delivered], using: [KeyPathComparator(\OrderTableRow.status)])
        XCTAssertEqual(sorted.map(\.id), ["B", "C", "A", "D"])
        let reversed = orderTableRowsSorted([shippedRow, lagging, printing, delivered],
                                            using: [KeyPathComparator(\OrderTableRow.status, order: .reverse)])
        XCTAssertEqual(reversed.map(\.id), ["C", "A", "D", "B"])
    }

    func testStatusFilterHint() {
        let lagging = Record(values: order(fulfillment: shipped))
        let plain = Record(values: order())
        XCTAssertEqual(orderStatusFilterLagHintText(status: "SHIPPED", loaded: []), orderStatusFilterLagHint)
        XCTAssertEqual(orderStatusFilterLagHint,
                       "Slant’s filter uses its own order status, so orders Studio shows as Shipped while Slant still says Printing or Submitted are listed under that status.")
        XCTAssertEqual(orderStatusFilterLagHintText(status: "PRINTING", loaded: [plain, lagging]), orderStatusFilterLagHint)
        XCTAssertEqual(orderStatusFilterLagHintText(status: " printing ", loaded: [lagging]), orderStatusFilterLagHint)
        XCTAssertNil(orderStatusFilterLagHintText(status: "PRINTING", loaded: [plain]))
        // Under Submitted only while a loaded Submitted order lags; a lagging Printing order doesn't count there.
        let laggingSubmitted = Record(values: order("SUBMITTED", fulfillment: shipped))
        XCTAssertEqual(orderStatusFilterLagHintText(status: "SUBMITTED", loaded: [laggingSubmitted]), orderStatusFilterLagHint)
        XCTAssertNil(orderStatusFilterLagHintText(status: "SUBMITTED", loaded: [lagging]))
        XCTAssertNil(orderStatusFilterLagHintText(status: "PRINTING", loaded: [laggingSubmitted]))
        XCTAssertNil(orderStatusFilterLagHintText(status: nil, loaded: [lagging]))
        XCTAssertNil(orderStatusFilterLagHintText(status: "  ", loaded: [lagging]))
        XCTAssertNil(orderStatusFilterLagHintText(status: "DRAFT", loaded: [lagging]))
        XCTAssertTrue(orderFilterEmptyDetail(OrderFilter(status: "SHIPPED")).hasSuffix(orderStatusFilterLagHint))
        XCTAssertTrue(orderFilterEmptyDetail(OrderFilter(status: "SHIPPED"), moreOnServer: true).hasSuffix(orderStatusFilterLagHint))
        XCTAssertEqual(orderFilterEmptyDetail(OrderFilter(status: "PRINTING")), "No orders with the status “Printing”.")
        // The Spending Report counts Printing and Submitted orders as spend, but a Shipped-filtered list leaves out the
        // ones Slant still lists that way.
        let notes = spendReportScopeNotes(searchActive: false, statusFilter: "SHIPPED", hasDateRange: false, moreOnServer: false)
        XCTAssertEqual(notes, ["The Orders list is filtered to Shipped orders, so only those are included. Orders Slant still lists as Printing or Submitted aren’t included, even if Studio shows them as Shipped."])
        XCTAssertTrue(spendReportCountedStatuses.isSuperset(of: ["PRINTING", "SUBMITTED"]))
        XCTAssertFalse(spendReportScopeNotes(searchActive: false, statusFilter: "PRINTING", hasDateRange: false,
                                             moreOnServer: false)[0].contains("Shipped"))
    }

    // MARK: Read-only advice

    func testAShippedPerRecordOrderIsNeverLateOrStuck() throws {
        let now = try XCTUnwrap(orderTimestamp("2026-01-11T12:00:00Z"))
        var late = order(fulfillment: shipped)
        late["arriveByDate"] = "2026-01-07"
        XCTAssertNil(orderAttention(late, now: now))
        XCTAssertNil(orderAttention(order(fulfillment: shipped), now: now))
        // Without the record, both alarms stand.
        late["fulfillment"] = NSNull()
        XCTAssertEqual(orderAttention(late, now: now), .pastArriveBy(try XCTUnwrap(orderArriveByDate(late))))
        if case .notShipped? = orderAttention(order(), now: now) {} else { XCTFail("expected Not shipped") }
        // A record that only says a label is waiting removes nothing.
        if case .notShipped? = orderAttention(order(fulfillment: ["status": "AWAITING_SHIPMENT", "labelPrinted": true]), now: now) {} else {
            XCTFail("expected Not shipped")
        }
        // A payment problem is never hidden by a record.
        XCTAssertEqual(orderAttention(order("PAYMENT_ERROR", fulfillment: shipped), now: now), .paymentProblem)
    }

    func testTheProblemMessageCarriesBothWords() {
        let message = orderProblemMessage(order: order(fulfillment: shipped), problem: .damaged, details: "")
        XCTAssertTrue(message.contains("Status: Printing · Shipping record: Shipped"), message)
        XCTAssertTrue(message.contains("Tracking number: TEST0001US"))
        let same = orderProblemMessage(order: order("SHIPPED", fulfillment: shipped), problem: .damaged, details: "")
        XCTAssertTrue(same.contains("Status: Shipped\n"), same)
        XCTAssertFalse(same.contains("Shipping record"))
        let waiting = orderProblemMessage(order: order(fulfillment: ["status": "AWAITING_SHIPMENT"]), problem: .late, details: "")
        XCTAssertTrue(waiting.contains("Status: Printing · Shipping record: Awaiting shipment"), waiting)
        let bare = orderProblemMessage(order: order(fulfillment: ["status": 3]), problem: .late, details: "")
        XCTAssertTrue(bare.contains("Status: Printing\n"), bare)
    }

    // MARK: Cancelling

    func testTheCancelReviewLeavesTheOutcomeToSlant() {
        let lagging = order(fulfillment: shipped)
        XCTAssertEqual(orderCancelSheetBody(order: lagging),
                       "Slant’s shipping record says this order has shipped, so Slant probably can’t stop the delivery. Slant decides whether to cancel it and what to refund.")
        XCTAssertEqual(orderCancelSheetBody("SHIPPED"), "This order already shipped, so Slant refunds it but can’t stop delivery.")
        XCTAssertEqual(orderShippingDetailsChangedMessage, "This order’s shipping record or tracking changed. Review it again.")
        for text in [orderCancelSheetBody(order: lagging), orderCancelSheetBody("SHIPPED"), orderShippingDetailsChangedMessage,
                     orderStatusFilterLagHint, orderStatusLagNote(lagging) ?? ""] {
            XCTAssertFalse(text.contains("'"), "straight apostrophe in “\(text)”")
        }
        XCTAssertEqual(orderCancelSheetTitle(orderDisplayStatus(lagging)), "Request a refund?")
        XCTAssertEqual(orderCancelActionTitle(orderDisplayStatus(lagging)), "Request Refund…")
        XCTAssertTrue(orderCancellationIsRefundOnly(orderDisplayStatus(lagging)))
        // Everything else keeps its own wording.
        XCTAssertEqual(orderCancelSheetBody(order: order()), orderCancelSheetBody("PRINTING"))
        XCTAssertEqual(orderCancelSheetBody(order: order(fulfillment: ["status": "AWAITING_SHIPMENT"])), orderCancelSheetBody("PRINTING"))
        XCTAssertEqual(orderCancelSheetBody(order: order("SHIPPED", fulfillment: shipped)), orderCancelSheetBody("SHIPPED"))
        XCTAssertEqual(orderCancelSheetBody(order: nil), orderCancelSheetBody(""))
        // Offering Cancel is still Slant's status alone.
        XCTAssertTrue(orderCanRequestCancellation("PRINTING"))
        XCTAssertFalse(orderCanRequestCancellation((order("CANCELLED", fulfillment: shipped)["status"] as? String) ?? ""))
    }

    func testTheCancelReCheckStopsWhenShippingDetailsChange() {
        let shown = order()
        let blocked = OrderConfirmRecheckResult.statusBlocked(orderShippingDetailsChangedMessage)
        // A record appeared, changed, or its tracking changed: stop, whatever the order status says.
        XCTAssertEqual(orderConfirmRecheck(method: "DELETE", shown: shown, latest: order(fulfillment: shipped)), blocked)
        XCTAssertEqual(orderConfirmRecheck(method: "DELETE", shown: order(fulfillment: ["status": "AWAITING_SHIPMENT"]),
                                           latest: order(fulfillment: ["status": "SHIPPED"])), blocked)
        XCTAssertEqual(orderConfirmRecheck(method: "DELETE", shown: order(fulfillment: shipped),
                                           latest: order(fulfillment: ["status": "SHIPPED", "trackingNumbers": ["TEST0001US", "NEW"]])), blocked)
        XCTAssertEqual(orderConfirmRecheck(method: "DELETE", shown: order(fulfillment: shipped), latest: order(fulfillment: NSNull())), blocked)
        // Unchanged details, including null vs absent and a reordered or repeated tracking list, go on as before.
        XCTAssertEqual(orderConfirmRecheck(method: "DELETE", shown: shown, latest: order(fulfillment: NSNull())), .proceed)
        XCTAssertEqual(orderConfirmRecheck(method: "DELETE", shown: order(fulfillment: shipped), latest: order(fulfillment: shipped)), .proceed)
        XCTAssertEqual(orderConfirmRecheck(method: "DELETE",
                                           shown: order(fulfillment: ["status": "SHIPPED", "trackingNumbers": ["A", "B"]]),
                                           latest: order(fulfillment: ["status": " shipped ", "trackingNumbers": ["B", "A", "A"]])),
                       .proceed)
        // It only adds a stop: a status change or an uncancellable status still stops with its own reason.
        XCTAssertEqual(orderConfirmRecheck(method: "DELETE", shown: shown, latest: order("SHIPPED", fulfillment: shipped)),
                       .statusBlocked("This order’s status changed. Review it again."))
        if case .proceed = orderConfirmRecheck(method: "DELETE", shown: order("CANCELLED", fulfillment: shipped),
                                               latest: order("CANCELLED", fulfillment: shipped)) {
            XCTFail("a cancelled order is never cancellable")
        }
    }

    func testPayIsNeverBlockedByAShippingRecord() {
        let draft = order("DRAFT")
        XCTAssertEqual(orderConfirmRecheck(method: "POST", shown: draft, latest: order("DRAFT", fulfillment: shipped)), .proceed)
        XCTAssertNil(workbenchCancelShippingDetailsMessage(method: "POST", preview: draft, fresh: order("DRAFT", fulfillment: shipped)))
        // Nor can a record ever make a non-draft payable.
        XCTAssertEqual(orderConfirmRecheck(method: "POST", shown: order(fulfillment: shipped), latest: order(fulfillment: shipped)),
                       .statusBlocked("Only drafts can be placed."))
    }

    func testTheWorkbenchCancelStopsToo() {
        XCTAssertEqual(workbenchCancelShippingDetailsMessage(method: "DELETE", preview: order(), fresh: order(fulfillment: shipped)),
                       orderShippingDetailsChangedMessage)
        XCTAssertNil(workbenchCancelShippingDetailsMessage(method: "DELETE", preview: order(fulfillment: shipped),
                                                          fresh: order(fulfillment: shipped)))
        XCTAssertNil(workbenchCancelShippingDetailsMessage(method: "GET", preview: order(), fresh: order(fulfillment: shipped)))
    }

    // MARK: The display status never reaches a write path

    /// The review sheet's gate takes the whole order and reads Slant's own status, so a lagging order is gated exactly
    /// as the same order without its shipping record. (Today Shipped and the production statuses are gated alike, so
    /// the outcome alone can't tell them apart; the source scan below is what catches a display status routed into a
    /// gate.)
    func testTheReviewGateUsesSlantsOwnStatus() {
        let lagging = order(fulfillment: shipped)
        let plain = order()
        for isPay in [true, false] {
            for loaded in [true, false] {
                for (succeeded, attempted) in [(false, false), (true, false), (false, true)] {
                    let gate = orderConfirmReviewGate(order: lagging, loaded: loaded, isPay: isPay,
                                                      writeSucceeded: succeeded, writeAttempted: attempted)
                    XCTAssertEqual(gate, orderConfirmReviewGate(order: plain, loaded: loaded, isPay: isPay,
                                                                writeSucceeded: succeeded, writeAttempted: attempted))
                    XCTAssertEqual(gate.enabled, orderConfirmFinalActionEnabled(writeSucceeded: succeeded, writeAttempted: attempted,
                                                                                 loaded: loaded, status: "PRINTING", isPay: isPay,
                                                                                 order: lagging))
                }
            }
        }
        // Cancel stays offered for a lagging Printing order; Pay stays refused.
        XCTAssertEqual(orderConfirmReviewGate(order: lagging, loaded: true, isPay: false, writeSucceeded: false, writeAttempted: false),
                       OrderConfirmReviewGate(enabled: true, reason: nil))
        XCTAssertEqual(orderConfirmReviewGate(order: lagging, loaded: true, isPay: true, writeSucceeded: false, writeAttempted: false),
                       OrderConfirmReviewGate(enabled: false, reason: "Only drafts can be placed."))
        // Drafts, cancelled orders and a missing order keep their own answers.
        XCTAssertTrue(orderConfirmReviewGate(order: order("DRAFT", fulfillment: shipped), loaded: true, isPay: true,
                                             writeSucceeded: false, writeAttempted: false).enabled)
        XCTAssertEqual(orderConfirmReviewGate(order: order("CANCELLED", fulfillment: shipped), loaded: true, isPay: false,
                                              writeSucceeded: false, writeAttempted: false),
                       OrderConfirmReviewGate(enabled: false, reason: "This order was already cancelled."))
        XCTAssertFalse(orderConfirmReviewGate(order: nil, loaded: true, isPay: false, writeSucceeded: false, writeAttempted: false).enabled)
    }

    /// A source check over Sources/SlantStudio: the display status, its helpers and anything computed from them never
    /// reach the code that decides pay, cancel, the lock, Pay Several Drafts or spend: not in a forbidden file, not as
    /// an argument anywhere inside a (multi-line) call to a write gate, not through a local `let`/`var`, and not inside
    /// a gate's own definition.
    func testTheDisplayStatusStaysOutOfEveryWritePath() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/SlantStudio")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 20)
        var sawSheet = false
        for file in files {
            let name = file.lastPathComponent
            let text = try String(contentsOf: file, encoding: .utf8)
            for leak in DisplayStatusLeakScan.leaks(in: text, forbiddenFile: DisplayStatusLeakScan.forbiddenFiles.contains(name)) {
                XCTFail("\(name): \(leak)")
            }
            if name == "OrdersView.swift" {
                // The review sheet asks only `orderConfirmReviewGate`, with the order it loaded, never a status-taking gate.
                let sheet = try XCTUnwrap(DisplayStatusLeakScan.declaration(named: "struct OrderActionConfirmSheet",
                                                                             in: DisplayStatusLeakScan.stripComments(text)))
                XCTAssertTrue(sheet.contains("orderConfirmReviewGate(order: fresh,"))
                for gate in ["orderConfirmFinalActionEnabled(", "workbenchChargeAllowed(", "orderCancelConfirmAllowed("] {
                    XCTAssertFalse(sheet.contains(gate), "the review sheet calls \(gate)")
                }
                sawSheet = true
            }
        }
        XCTAssertTrue(sawSheet)
    }

    /// The scan itself catches the realistic regressions and passes clean code.
    func testTheLeakScanCatchesRoutedDisplayStatuses() {
        let multiLine = """
        var enabled: Bool {
            orderConfirmFinalActionEnabled(
                writeSucceeded: false,
                loaded: true,
                status: copyStatus,
                isPay: false
            )
        }
        """
        XCTAssertFalse(DisplayStatusLeakScan.leaks(in: multiLine, forbiddenFile: false).isEmpty)
        let routed = """
        func check(order: [String: Any]) -> Bool {
            let shown = orderDisplayStatus(order)
            let upper = shown
                .uppercased()
            return orderCancelConfirmAllowed(status: upper,
                                             loaded: true).0
        }
        """
        XCTAssertFalse(DisplayStatusLeakScan.leaks(in: routed, forbiddenFile: false).isEmpty)
        let lock = """
        store.markOutcomeUnknown(orderID: id, action: .cancel,
                                 reviewedStatus: orderDisplayStatus(latest))
        """
        XCTAssertFalse(DisplayStatusLeakScan.leaks(in: lock, forbiddenFile: false).isEmpty)
        let insideGate = """
        func orderCanRequestCancellation(_ status: String) -> Bool {
            let order: [String: Any] = ["status": status]
            return !orderStatusLagsShippingRecord(order)
        }
        """
        XCTAssertFalse(DisplayStatusLeakScan.leaks(in: insideGate, forbiddenFile: false).isEmpty)
        XCTAssertFalse(DisplayStatusLeakScan.leaks(in: "let title = orderDisplayStatus(o)", forbiddenFile: true).isEmpty)
        XCTAssertEqual(DisplayStatusLeakScan.leaks(in: "let x = 1 // orderDisplayStatus", forbiddenFile: true), [])
        // Clean: wording beside a gate, a gate fed Slant's own status, an `if` whose body shows the display word.
        let clean = """
        var copyStatus: String { fresh.map(orderDisplayStatus) ?? "" }
        var title: String { orderCancelSheetTitle(copyStatus) }
        var allowed: Bool { orderCancelConfirmAllowed(status: fresh?["status"] as? String, loaded: true).0 }
        func view() {
            if canCancelSelected {
                Button(orderCancelActionTitle(orderDisplayStatus(displayed))) {}
            }
            store.markOutcomeUnknown(orderID: id, action: .cancel, reviewedStatus: latest["status"] as? String)
        }
        """
        XCTAssertEqual(DisplayStatusLeakScan.leaks(in: clean, forbiddenFile: false), [])
    }
}

/// A small, conservative scanner for `testTheDisplayStatusStaysOutOfEveryWritePath`. It errs towards flagging: strings
/// and comments are handled only roughly, which can only widen the text a call or declaration covers.
private enum DisplayStatusLeakScan {
    /// The display status, its helpers and the names Studio gives it.
    static let displayNames: Set<String> = ["orderDisplayStatus", "orderDisplayStatusTitle", "orderStatusLagsShippingRecord",
                                            "orderStatusLagNote", "copyStatus", "displayStatus"]
    static let forbiddenFiles: Set<String> = ["BatchPay.swift", "SpendReport.swift", "StudioStore.swift", "APIWorkbenchView.swift"]
    /// Calls, properties and definitions that decide pay, cancel, the lock, Pay Several Drafts or spend.
    static let writeNames: Set<String> = [
        "orderCanRequestCancellation", "orderConfirmRecheck", "markOutcomeUnknown", "reviewedStatus",
        "batchPayOutcomeAfterSuccess", "batchPayAcceptedOutcomeStaysLocked", "orderPlacedStatuses",
        "spendReportCountedStatuses", "unknownOutcomeResolvedByReload", "orderCancelConfirmAllowed",
        "workbenchCancelAllowed", "orderConfirmFinalActionEnabled", "workbenchChargeAllowed", "canCancelSelected",
        "batchPayIsDraft", "batchPayExclusionReason", "orderConfirmReviewGate", "reviewGate", "finalActionEnabled",
        "workbenchCancelShippingDetailsMessage", "orderShippingDetails"
    ]
    /// Too general to carry taint from a `var` (a SwiftUI view's `body` shows the display word legitimately).
    static let neverTainted: Set<String> = ["body"]

    static func leaks(in source: String, forbiddenFile: Bool) -> [String] {
        let code = Array(stripComments(source))
        var result: [String] = []
        if forbiddenFile {
            for name in identifiers(in: String(code)).intersection(displayNames).sorted() { result.append("uses \(name)") }
        }
        // Names declared from the display status (`let shown = orderDisplayStatus(order)`), each tainted throughout the
        // block it's declared in (a type's properties can be used before they're declared), to a fixed point.
        let scopes = braceScopes(code)
        let declared = declarations(in: code).map { declaration in
            (name: declaration.name, at: declaration.at, used: identifiers(in: String(code[declaration.value])),
             scope: max(scopes.enclosingOpen[declaration.at], 0)...scopes.enclosingEnd(declaration.at))
        }
        var regions: [String: [ClosedRange<Int>]] = [:]
        func isTainted(_ name: String, at position: Int) -> Bool {
            displayNames.contains(name) || (regions[name] ?? []).contains { $0.contains(position) }
        }
        var changed = true
        while changed {
            changed = false
            for item in declared where !neverTainted.contains(item.name) && !isTainted(item.name, at: item.at) {
                if item.used.contains(where: { isTainted($0, at: item.at) }) {
                    regions[item.name, default: []].append(item.scope)
                    changed = true
                }
            }
        }
        for (name, range) in writeSites(in: code) {
            let used = identifiers(in: String(code[range])).filter { isTainted($0, at: range.lowerBound) }
            if !used.isEmpty {
                let snippet = String(code[range]).split(separator: "\n").joined(separator: " ").prefix(160)
                result.append("\(name) gets \(used.sorted().joined(separator: ", ")): \(snippet)")
            }
        }
        return result
    }

    /// Where each `{ … }` block ends, to bound a local name's taint to the block that declares it.
    private struct BraceScopes {
        /// For each character, the index of the innermost unclosed `{` before it, or -1 at file scope.
        var enclosingOpen: [Int]
        var closeOf: [Int: Int]
        var count: Int
        func enclosingEnd(_ index: Int) -> Int {
            let open = enclosingOpen[index]
            return open < 0 ? count - 1 : (closeOf[open] ?? count - 1)
        }
    }

    private static func braceScopes(_ chars: [Character]) -> BraceScopes {
        var enclosing = [Int](repeating: -1, count: chars.count)
        var closeOf: [Int: Int] = [:]
        var stack: [Int] = []
        var inString = false
        for i in chars.indices {
            enclosing[i] = stack.last ?? -1
            let c = chars[i]
            if c == "\"" && (i == 0 || chars[i - 1] != "\\") { inString.toggle() }
            if inString { continue }
            if c == "{" { stack.append(i) }
            if c == "}", let open = stack.popLast() { closeOf[open] = i }
        }
        return BraceScopes(enclosingOpen: enclosing, closeOf: closeOf, count: chars.count)
    }

    /// Drops `//` comments that start a line or follow whitespace (so `https://` in a string stays).
    static func stripComments(_ source: String) -> String {
        source.replacingOccurrences(of: #"(?m)(^|\s)//.*$"#, with: "$1", options: .regularExpression)
    }

    /// The text of a declaration that starts with `header`, through its closing brace.
    static func declaration(named header: String, in source: String) -> String? {
        let chars = Array(source)
        guard let found = source.range(of: header) else { return nil }
        let start = source.distance(from: source.startIndex, to: found.lowerBound)
        guard let open = chars[start...].firstIndex(of: "{"), let end = matchingClose(chars, from: open) else { return nil }
        return String(chars[start...end])
    }

    static func identifiers(in text: String) -> Set<String> {
        let regex = try! NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_]*"#)
        let ns = text as NSString
        return Set(regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) })
    }

    /// Word-boundary occurrences of `names` in `chars`: (name, start index, end index).
    private static func occurrences(of names: Set<String>, in chars: [Character]) -> [(String, Int, Int)] {
        var result: [(String, Int, Int)] = []
        var i = 0
        while i < chars.count {
            if isIdentifierStart(chars[i]), i == 0 || !isIdentifierChar(chars[i - 1]) {
                var j = i
                while j < chars.count, isIdentifierChar(chars[j]) { j += 1 }
                let word = String(chars[i..<j])
                if names.contains(word) { result.append((word, i, j)) }
                i = j
            } else {
                i += 1
            }
        }
        return result
    }

    /// Every `let`/`var` declaration's name and the text that gives it its value: the initialiser through the end of
    /// its statement, or a computed property's body.
    private static func declarations(in chars: [Character]) -> [(name: String, at: Int, value: ClosedRange<Int>)] {
        var result: [(name: String, at: Int, value: ClosedRange<Int>)] = []
        for (_, start, end) in occurrences(of: ["let", "var"], in: chars) {
            var i = end
            while i < chars.count, chars[i] == " " { i += 1 }
            guard i < chars.count, isIdentifierStart(chars[i]) else { continue }
            var j = i
            while j < chars.count, isIdentifierChar(chars[j]) { j += 1 }
            if let range = valueRange(chars, after: j, binding: isConditionBinding(chars, keywordAt: start)) {
                result.append((String(chars[i..<j]), start, range))
            }
        }
        return result
    }

    /// `if let x = …`, `guard let x = …, let y = …`, `while let …`: the value ends at a `,` or the block's `{`, so a
    /// body that shows the display word doesn't taint the bound name.
    private static func isConditionBinding(_ chars: [Character], keywordAt start: Int) -> Bool {
        if ["if", "guard", "while"].contains(precedingWord(chars, before: start)) { return true }
        var i = start - 1
        while i >= 0, chars[i] == " " { i -= 1 }
        return i >= 0 && chars[i] == ","
    }

    /// The text each write name's use or definition covers: a call's arguments (also after `.member`), a labelled
    /// argument's expression, a `func`'s parameters and body, or a `let`/`var`'s value.
    private static func writeSites(in chars: [Character]) -> [(String, ClosedRange<Int>)] {
        var result: [(String, ClosedRange<Int>)] = []
        for (name, start, end) in occurrences(of: writeNames, in: chars) {
            let before = precedingWord(chars, before: start)
            if before == "func" {
                guard let open = nextIndex(of: "(", in: chars, from: end), let close = matchingClose(chars, from: open) else { continue }
                var last = close
                if let body = nextIndex(of: "{", in: chars, from: close + 1, stoppingAt: ["}"]),
                   let bodyEnd = matchingClose(chars, from: body) { last = bodyEnd }
                result.append((name, open...last))
                continue
            }
            if before == "let" || before == "var" {
                let keyword = start - 1 - chars[..<start].reversed().prefix { $0 == " " }.count - before.count + 1
                if let range = valueRange(chars, after: end, binding: isConditionBinding(chars, keywordAt: keyword)) {
                    result.append((name, range))
                }
                continue
            }
            var i = end
            while i < chars.count, chars[i] == " " { i += 1 }
            guard i < chars.count else { continue }
            switch chars[i] {
            case "(":
                if let close = matchingClose(chars, from: i) { result.append((name, i...close)) }
            case ".":
                var j = i + 1
                while j < chars.count, isIdentifierChar(chars[j]) { j += 1 }
                if j < chars.count, chars[j] == "(", let close = matchingClose(chars, from: j) { result.append((name, j...close)) }
            case ":":
                // A labelled argument (`reviewedStatus: …`): up to the next `,` or closing bracket at its own depth.
                if let range = expressionRange(chars, from: i + 1) { result.append((name, range)) }
            default:
                break
            }
        }
        return result
    }

    /// After a declared name: a computed property's `{ … }`, or `= …` through the end of the statement. Nil for a
    /// stored property with only a type.
    private static func valueRange(_ chars: [Character], after index: Int, binding: Bool) -> ClosedRange<Int>? {
        var i = index
        var depth = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\n" && depth == 0 { return nil }
            if c == "=" && depth == 0 && (i + 1 >= chars.count || chars[i + 1] != "=") {
                return expressionRange(chars, from: i + 1, stopAtComma: binding, stopAtBrace: binding)
            }
            if c == "," && depth == 0 && binding { return nil }
            if c == "{" && depth == 0 {
                return matchingClose(chars, from: i).map { i...$0 }
            }
            if "([<".contains(c) { depth += 1 }
            if ")]".contains(c) || (c == ">" && chars[i - 1] != "-") { depth -= 1 }
            if depth < 0 { return nil }
            i += 1
        }
        return nil
    }

    /// From `start` to the end of an expression: a newline (unless the statement plainly continues), a `,` (when
    /// `stopAtComma`) or an unmatched closing bracket, at depth 0.
    private static func expressionRange(_ chars: [Character], from start: Int, stopAtComma: Bool = true,
                                        stopAtBrace: Bool = false) -> ClosedRange<Int>? {
        var i = start
        var depth = 0
        var inString = false
        var lastNonSpace: Character?
        while i < chars.count {
            let c = chars[i]
            if c == "\"" && (i == 0 || chars[i - 1] != "\\") { inString.toggle() }
            if !inString {
                if c == "{" && depth == 0 && stopAtBrace { break }
                if "([{".contains(c) { depth += 1 }
                if ")]}".contains(c) {
                    if depth == 0 { break }
                    depth -= 1
                }
                if depth == 0 && stopAtComma && c == "," { break }
                if depth == 0 && c == "\n" {
                    var k = i + 1
                    while k < chars.count, chars[k] == " " { k += 1 }
                    let endsOpen = lastNonSpace.map { "=+-*/&|?:.(,".contains($0) } ?? true
                    let nextContinues = k < chars.count && ".?:&|+*/".contains(chars[k])
                    if !(endsOpen || nextContinues) { break }
                }
            }
            if c != " " && c != "\n" { lastNonSpace = c }
            i += 1
        }
        return i > start ? start...(i - 1) : nil
    }

    private static func matchingClose(_ chars: [Character], from open: Int) -> Int? {
        var depth = 0
        var inString = false
        var i = open
        while i < chars.count {
            let c = chars[i]
            if c == "\"" && (i == 0 || chars[i - 1] != "\\") { inString.toggle() }
            if !inString {
                if "([{".contains(c) { depth += 1 }
                if ")]}".contains(c) {
                    depth -= 1
                    if depth == 0 { return i }
                }
            }
            i += 1
        }
        return nil
    }

    private static func nextIndex(of target: Character, in chars: [Character], from start: Int,
                                  stoppingAt stops: Set<Character> = []) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == target { return i }
            if stops.contains(chars[i]) { return nil }
            i += 1
        }
        return nil
    }

    private static func precedingWord(_ chars: [Character], before index: Int) -> String {
        var i = index - 1
        while i >= 0, chars[i] == " " { i -= 1 }
        var j = i
        while j >= 0, isIdentifierChar(chars[j]) { j -= 1 }
        return i > j ? String(chars[(j + 1)...i]) : ""
    }

    private static func isIdentifierStart(_ c: Character) -> Bool { c == "_" || (c.isASCII && c.isLetter) }
    private static func isIdentifierChar(_ c: Character) -> Bool { c == "_" || (c.isASCII && (c.isLetter || c.isNumber)) }
}
