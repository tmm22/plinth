import Foundation

// MARK: - Quitting with paid design work open
//
// The design sheets (Generate a Replica, Design an Accessory, Review for Printing) keep everything in memory, and each
// asks before its own Close discards something billed. ⌘Q used to quit at once, and the next launch removes their temp
// folders, so a paid model or design was gone without a word. `DesignQuitRegistry` lets the quit question
// (`plinthQuitQuestion`) see the same conditions the sheets' close questions use. Memory only: nothing here is saved,
// and it holds no names, prices, photos or customer data, only which kinds of work are open.

/// One kind of paid design work that quitting would lose, in the order the quit question names them.
enum DesignQuitItem: Int, CaseIterable, Comparable, Sendable {
    /// A replica generation sent to Meshy or Tripo whose model hasn't arrived and been read yet (the create, the
    /// waiting, the download). It outlives its sheet until the outcome is recorded.
    case generationInFlight
    /// A generated replica not saved to the library (`ReplicaGeneratorSession.hasUnsavedModel`).
    case unsavedReplica
    /// Design an Accessory with a design started (`accessoryCloseConfirmation`'s `designStarted`).
    case accessoryDesign
    /// Design an Accessory holding or fetching Claude's ideas, before a design starts.
    case accessoryIdeas
    /// Review for Printing while Claude is replying (`printReviewCloseConfirmation`'s `asking`).
    case printReviewReply
    /// Review for Printing with ticked steps of Claude's plan not yet run.
    case printReviewPlan

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// What the quit question says would be lost.
    var lostText: String {
        switch self {
        case .generationInFlight: "a replica that is still being generated"
        case .unsavedReplica: "a generated replica that isn’t in your library"
        case .accessoryDesign: "the accessory design conversation with Claude, and any designs from it you haven’t saved"
        case .accessoryIdeas: "Claude’s accessory ideas"
        case .printReviewReply: "the print review Claude is writing"
        case .printReviewPlan: "Claude’s print review plan, with steps you ticked but haven’t run"
        }
    }
}

/// An open design sheet's state, read live when the seller quits. Each sheet computes it from the same conditions as its
/// own close question, so the two never disagree.
@MainActor protocol DesignQuitSource: AnyObject {
    var designQuitItems: [DesignQuitItem] { get }
}

/// Open design sheets and replica generations in flight. Sources are held weakly and are also unregistered when their
/// sheet goes, so a closed sheet never leaves a stale question; generation tokens end when the outcome is recorded.
@MainActor final class DesignQuitRegistry {
    static let shared = DesignQuitRegistry()

    private struct WeakSource {
        weak var source: (any DesignQuitSource)?
    }

    private var sources: [ObjectIdentifier: WeakSource] = [:]
    private var generations: Set<UUID> = []

    init() {}

    func register(_ source: any DesignQuitSource) {
        sources[ObjectIdentifier(source)] = WeakSource(source: source)
    }

    func unregister(_ source: any DesignQuitSource) {
        sources[ObjectIdentifier(source)] = nil
    }

    /// A paid generation was handed to the service; `endGeneration` once its outcome is recorded (a model kept, or a
    /// stop remembered in `ImageTo3DConnection.unconfirmedRequests`).
    func beginGeneration() -> UUID {
        let token = UUID()
        generations.insert(token)
        return token
    }

    func endGeneration(_ token: UUID) { generations.remove(token) }

    /// Everything open now, sorted and without repeats.
    var items: [DesignQuitItem] {
        sources = sources.filter { $0.value.source != nil }
        var found = Set(sources.values.compactMap(\.source).flatMap(\.designQuitItems))
        if !generations.isEmpty { found.insert(.generationInFlight) }
        return found.sorted()
    }
}

/// The quit question for paid design work, or nil to quit at once. `items` is what open sheets would lose;
/// `unconfirmedGenerations` and `unconfirmedOverflowed` are `ImageTo3DConnection`'s records of paid 3D requests whose
/// outcome is unknown, which quitting forgets (so Generate would no longer ask before paying again).
func designWorkQuitQuestion(items: [DesignQuitItem], unconfirmedGenerations: Int,
                            unconfirmedOverflowed: Bool = false) -> (title: String, message: String)? {
    let lost = Array(Set(items)).sorted()
    let unconfirmed = max(0, unconfirmedGenerations)
    let forgets = unconfirmed > 0 || unconfirmedOverflowed
    guard !lost.isEmpty || forgets else { return nil }
    var sentences: [String] = []
    let kept = lost.filter { $0 != .generationInFlight }
    if !kept.isEmpty {
        let texts = kept.map(\.lostText)
        let list = texts.count == 1 ? texts[0] : texts.dropLast().joined(separator: ", ") + " and " + texts[texts.count - 1]
        sentences.append(kept.count == 1
            ? "Plinth doesn’t keep \(list), so quitting loses it. It was billed to your account, and getting it back "
              + "means asking, and paying, again."
            : "Plinth doesn’t keep \(list), so quitting loses them. They were billed to your account, and getting them "
              + "back means asking, and paying, again.")
    }
    if lost.contains(.generationInFlight) {
        sentences.append("A replica is still being generated. Quitting doesn’t stop the request already sent, so it may still "
                         + "be charged, and Plinth can’t collect the model once it has quit.")
    }
    if forgets {
        let what: String
        if unconfirmed == 0 {
            what = "earlier 3D generation requests"
        } else {
            what = unconfirmed == 1 ? "a 3D generation request" : "\(unconfirmed) 3D generation requests"
        }
        let also = sentences.isEmpty ? "" : "also "
        sentences.append("Plinth \(also)forgets that \(what) this session may have spent credits, so it can’t warn you "
                         + "before you generate again. Check the service’s dashboard first.")
    }
    let forgetTitle = unconfirmed == 1 && !unconfirmedOverflowed
        ? "Quit and forget a 3D generation that may have been charged?"
        : "Quit and forget 3D generations that may have been charged?"
    let title = lost.isEmpty ? forgetTitle : "Quit and lose paid design work?"
    return (title, sentences.joined(separator: " "))
}

/// What Review for Printing would lose on quitting: the same conditions as its Close (`printReviewCloseConfirmation`).
func printReviewDesignQuitItems(hasPlan: Bool, asking: Bool, savedCopy: Bool) -> [DesignQuitItem] {
    guard printReviewCloseConfirmation(hasPlan: hasPlan, asking: asking, savedCopy: savedCopy) != nil else { return [] }
    return asking ? [.printReviewReply] : [.printReviewPlan]
}

/// What Design an Accessory would lose on quitting: the same conditions as its Close (`accessoryCloseConfirmation`).
func accessoryDesignQuitItems(designStarted: Bool, ideasHeld: Bool, suggesting: Bool) -> [DesignQuitItem] {
    guard accessoryCloseConfirmation(designStarted: designStarted, ideasHeld: ideasHeld, suggesting: suggesting) != nil else {
        return []
    }
    return designStarted ? [.accessoryDesign] : [.accessoryIdeas]
}

/// What the replica sheet would lose on quitting. A generation in flight is counted by its own token, and a stop whose
/// outcome is unknown by `ImageTo3DConnection.unconfirmedRequests` (`imageTo3DStopIsUnconfirmed`; a conversion that
/// was refused or ended is one, since the paid model waits for Try Conversion Again). Close also asks after a model too
/// large to read, which stays on its dashboard; quitting loses nothing there that closing doesn't, so it doesn't ask. A
/// task the service ended asks neither: nothing runs, nothing is recorded, and it is usually refunded.
func replicaDesignQuitItems(hasUnsavedModel: Bool) -> [DesignQuitItem] {
    hasUnsavedModel ? [.unsavedReplica] : []
}
