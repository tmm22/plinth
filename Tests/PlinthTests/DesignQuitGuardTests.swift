import XCTest
@testable import Plinth

/// Quitting with paid design work open (DesignQuitGuard.swift): the question's wording and precedence, its agreement
/// with each sheet's own close question, and the registry's lifetime rules.
@MainActor
final class DesignQuitGuardTests: XCTestCase {
    private final class FakeSource: DesignQuitSource {
        var designQuitItems: [DesignQuitItem]
        init(_ items: [DesignQuitItem]) { designQuitItems = items }
    }

    // MARK: The question

    func testNothingAtStakeQuitsAtOnce() {
        XCTAssertNil(designWorkQuitQuestion(items: [], unconfirmedGenerations: 0))
        XCTAssertNil(designWorkQuitQuestion(items: [], unconfirmedGenerations: -2))
        XCTAssertNil(plinthQuitQuestion(writes: [], dapiUnconfirmedOrders: 0, dapiUnknownCancels: 0, designWork: [],
                                        unconfirmedGenerations: 0, unconfirmedGenerationsOverflowed: false))
    }

    /// Every combination of open work and unconfirmed records: a question exactly when something is at stake, naming
    /// each kind of work and nothing else.
    func testEveryCombination() throws {
        let all = DesignQuitItem.allCases
        for mask in 0..<(1 << all.count) {
            let items = all.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            for unconfirmed in [0, 1, 3] {
                for overflowed in [false, true] {
                    let question = designWorkQuitQuestion(items: items, unconfirmedGenerations: unconfirmed,
                                                          unconfirmedOverflowed: overflowed)
                    let atStake = !items.isEmpty || unconfirmed > 0 || overflowed
                    guard atStake else { XCTAssertNil(question); continue }
                    let q = try XCTUnwrap(question, "\(items) \(unconfirmed) \(overflowed)")
                    XCTAssertEqual(q.title, items.isEmpty ? "Quit with unconfirmed 3D generations?" : "Quit and lose paid design work?")
                    for item in all where item != .generationInFlight {
                        XCTAssertEqual(q.message.contains(item.lostText), items.contains(item), "\(item) in \(items)")
                    }
                    XCTAssertEqual(q.message.contains("still being generated"), items.contains(.generationInFlight))
                    XCTAssertEqual(q.message.contains("forgets that"), unconfirmed > 0 || overflowed)
                    if unconfirmed > 1 { XCTAssertTrue(q.message.contains("\(unconfirmed) 3D generation requests")) }
                    if unconfirmed == 1 { XCTAssertTrue(q.message.contains("a 3D generation request ")) }
                    if unconfirmed == 0, overflowed { XCTAssertTrue(q.message.contains("earlier 3D generation requests")) }
                    // Plain words: no prices, promises or strength claims.
                    for banned in ["$", "guarantee", "safe", "strong", "will be refunded"] {
                        XCTAssertFalse(q.message.lowercased().contains(banned), "\(banned) in \(q.message)")
                    }
                }
            }
        }
    }

    func testRepeatsAndOrderDontChangeTheQuestion() {
        let a = designWorkQuitQuestion(items: [.printReviewPlan, .unsavedReplica, .unsavedReplica], unconfirmedGenerations: 0)
        let b = designWorkQuitQuestion(items: [.unsavedReplica, .printReviewPlan], unconfirmedGenerations: 0)
        XCTAssertEqual(a?.title, b?.title)
        XCTAssertEqual(a?.message, b?.message)
        XCTAssertTrue(a?.message.contains("a generated replica that isn’t in your library and Claude’s print review plan") == true)
        XCTAssertTrue(a?.message.contains("They were billed") == true)
        let one = designWorkQuitQuestion(items: [.accessoryIdeas], unconfirmedGenerations: 0)
        XCTAssertTrue(one?.message.contains("It was billed") == true)
    }

    func testOnlyAnInFlightGenerationSaysQuittingDoesntStopIt() throws {
        let q = try XCTUnwrap(designWorkQuitQuestion(items: [.generationInFlight], unconfirmedGenerations: 0))
        XCTAssertTrue(q.message.contains("Quitting doesn’t stop the request already sent"))
        XCTAssertFalse(q.message.contains("Plinth doesn’t keep"))
    }

    /// Slant writes first, then unclear 3DAPI orders, then design work; the earlier questions are unchanged.
    func testPrecedence() throws {
        let design: [DesignQuitItem] = [.unsavedReplica]
        let slant = try XCTUnwrap(plinthQuitQuestion(writes: [.payment], dapiUnconfirmedOrders: 1, dapiUnknownCancels: 0,
                                                     designWork: design, unconfirmedGenerations: 2))
        XCTAssertEqual(slant.title, slantWritesQuitQuestion([.payment])?.title)
        XCTAssertEqual(slant.message, slantWritesQuitQuestion([.payment])?.message)

        let dapi = try XCTUnwrap(plinthQuitQuestion(writes: [], dapiUnconfirmedOrders: 1, dapiUnknownCancels: 0,
                                                    designWork: design, unconfirmedGenerations: 2))
        XCTAssertEqual(dapi.message, dapiUnclearOrdersQuitQuestion(unconfirmedOrders: 1, unknownCancels: 0)?.message)

        let ours = try XCTUnwrap(plinthQuitQuestion(writes: [], dapiUnconfirmedOrders: 0, dapiUnknownCancels: 0,
                                                    designWork: design, unconfirmedGenerations: 2))
        XCTAssertEqual(ours.message, designWorkQuitQuestion(items: design, unconfirmedGenerations: 2)?.message)

        let records = try XCTUnwrap(plinthQuitQuestion(writes: [], dapiUnconfirmedOrders: 0, dapiUnknownCancels: 0,
                                                       unconfirmedGenerationsOverflowed: true))
        XCTAssertEqual(records.title, "Quit with unconfirmed 3D generations?")

        // The existing call, without design work, behaves as before.
        XCTAssertNil(plinthQuitQuestion(writes: [], dapiUnconfirmedOrders: 0, dapiUnknownCancels: 0))
        XCTAssertEqual(plinthQuitQuestion(writes: [.upload], dapiUnconfirmedOrders: 0, dapiUnknownCancels: 0)?.message,
                       slantWritesQuitQuestion([.upload])?.message)
    }

    // MARK: Agreement with each sheet's Close

    func testPrintReviewAsksExactlyWhenItsCloseDoes() {
        for hasPlan in [false, true] {
            for asking in [false, true] {
                for savedCopy in [false, true] {
                    let close = printReviewCloseConfirmation(hasPlan: hasPlan, asking: asking, savedCopy: savedCopy)
                    let items = printReviewDesignQuitItems(hasPlan: hasPlan, asking: asking, savedCopy: savedCopy)
                    XCTAssertEqual(items.isEmpty, close == nil, "\(hasPlan) \(asking) \(savedCopy)")
                    if !items.isEmpty { XCTAssertEqual(items, asking ? [.printReviewReply] : [.printReviewPlan]) }
                }
            }
        }
    }

    func testAccessoryDesignerAsksExactlyWhenItsCloseDoes() {
        for started in [false, true] {
            for ideas in [false, true] {
                for suggesting in [false, true] {
                    let close = accessoryCloseConfirmation(designStarted: started, ideasHeld: ideas, suggesting: suggesting)
                    let items = accessoryDesignQuitItems(designStarted: started, ideasHeld: ideas, suggesting: suggesting)
                    XCTAssertEqual(items.isEmpty, close == nil, "\(started) \(ideas) \(suggesting)")
                    if !items.isEmpty { XCTAssertEqual(items, started ? [.accessoryDesign] : [.accessoryIdeas]) }
                }
            }
        }
    }

    /// An unsaved replica asks on both paths. Every stop the replica's Close warns about whose outcome is unknown is
    /// recorded in the session's unconfirmed requests, which the quit question counts; the known outcomes (a task the
    /// service ended, a model too large to read) lose nothing on quitting.
    func testReplicaAgreesWithItsClose() {
        XCTAssertEqual(replicaDesignQuitItems(hasUnsavedModel: true), [.unsavedReplica])
        XCTAssertNotNil(replicaCloseWarning(hasUnsavedModel: true, lastStop: nil, service: .meshy))
        XCTAssertEqual(replicaDesignQuitItems(hasUnsavedModel: false), [])
        XCTAssertNil(replicaCloseWarning(hasUnsavedModel: false, lastStop: nil, service: .meshy))

        let reasons: [ImageTo3DStopReason] = [.notSent, .outcomeUnknown, .taskEnded(.failed), .conversionRefused, .timedOut,
                                              .statusUnreadable, .downloadFailed, .modelTooLarge, .cancelled]
        for reason in reasons {
            for taskID in [nil, "t1"] as [String?] {
                let stop = ImageTo3DStop(reason: reason, stage: .generating, service: .tripo, taskID: taskID, detail: "")
                let closeWarns = replicaCloseWarning(hasUnsavedModel: false, lastStop: stop, service: .tripo) != nil
                let suite = testDefaultsSuiteName("DesignQuit")
                let defaults = UserDefaults(suiteName: suite)!
                defer { removeTestDefaultsSuite(defaults, named: suite) }
                let connection = ImageTo3DConnection(defaults: defaults)
                connection.rememberUnconfirmed(stop)
                let quitAsks = designWorkQuitQuestion(items: [], unconfirmedGenerations: connection.unconfirmedRequests.count,
                                                      unconfirmedOverflowed: connection.unconfirmedRequestsOverflowed) != nil
                if quitAsks { XCTAssertTrue(closeWarns, "\(reason) \(String(describing: taskID))") }
                if closeWarns, reason != .modelTooLarge, reason != .taskEnded(.failed) {
                    XCTAssertTrue(quitAsks, "\(reason) \(String(describing: taskID))")
                }
            }
        }
    }

    // MARK: The registry

    func testRegistryReadsSourcesLive() {
        let registry = DesignQuitRegistry()
        let source = FakeSource([])
        registry.register(source)
        XCTAssertEqual(registry.items, [])
        source.designQuitItems = [.printReviewPlan, .accessoryDesign]
        XCTAssertEqual(registry.items, [.accessoryDesign, .printReviewPlan])
        source.designQuitItems = []
        XCTAssertEqual(registry.items, [])
    }

    func testUnregisterAndDeallocationLeaveNothingBehind() {
        let registry = DesignQuitRegistry()
        let kept = FakeSource([.unsavedReplica])
        registry.register(kept)
        registry.register(kept)
        XCTAssertEqual(registry.items, [.unsavedReplica])
        registry.unregister(kept)
        XCTAssertEqual(registry.items, [])
        registry.unregister(kept)

        // A sheet torn down without its onDisappear: the weak reference goes with it.
        var gone: FakeSource? = FakeSource([.accessoryIdeas])
        registry.register(gone!)
        XCTAssertEqual(registry.items, [.accessoryIdeas])
        gone = nil
        XCTAssertEqual(registry.items, [])
    }

    func testTwoSheetsAndGenerationsCombine() {
        let registry = DesignQuitRegistry()
        let review = FakeSource([.printReviewReply])
        let replica = FakeSource([.unsavedReplica])
        registry.register(review)
        registry.register(replica)
        let first = registry.beginGeneration()
        let second = registry.beginGeneration()
        XCTAssertEqual(registry.items, [.generationInFlight, .unsavedReplica, .printReviewReply])
        registry.endGeneration(first)
        XCTAssertEqual(registry.items, [.generationInFlight, .unsavedReplica, .printReviewReply])
        registry.endGeneration(second)
        registry.endGeneration(second)
        registry.unregister(review)
        XCTAssertEqual(registry.items, [.unsavedReplica])
    }

    // MARK: The sheets' own sources

    func testFreshSessionsHaveNothingAtStake() {
        let suite = testDefaultsSuiteName("DesignQuitSessions")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaultsSuite(defaults, named: suite) }
        let replica = ReplicaGeneratorSession(connection: ImageTo3DConnection(defaults: defaults))
        XCTAssertEqual(replica.designQuitItems, [])
        XCTAssertFalse(replica.hasUnsavedModel)
        let review = PrintReviewSession()
        XCTAssertEqual(review.designQuitItems, [])
        XCTAssertNil(review.closeConfirmation)
        let tracker = AccessoryDesignQuitTracker()
        XCTAssertEqual(tracker.designQuitItems, [])
    }

    func testAccessoryTrackerFollowsTheRunAndIdeas() {
        let tracker = AccessoryDesignQuitTracker()
        let run = AccessoryDesignRun(send: { _, _ in throw CancellationError() }, render: { _, _ in throw CancellationError() })
        tracker.run = run
        XCTAssertEqual(tracker.designQuitItems, [], "Not started: Close doesn't ask")
        run.start(firstTurn: .user([.text("Make a stand")]))
        XCTAssertEqual(tracker.designQuitItems, [.accessoryDesign])
        run.stop()
    }
}
