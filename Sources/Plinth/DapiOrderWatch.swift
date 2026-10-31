import Foundation

// The 3DAPI order watch. PLACEHOLDER for the shared interface: the insights implementer replaces the body, keeping
// `shared`, `badgeCount` and `setActive(_:)`, which the sidebar and the service choice use.

@MainActor final class DapiOrderWatch: ObservableObject {
    static let shared = DapiOrderWatch()

    /// Orders whose status changed to one worth a look since the seller last viewed Orders (the sidebar badge).
    @Published private(set) var badgeCount = 0

    /// Starts (true) or stops (false) watching; called when 3DAPI becomes or stops being the print service, and
    /// when the key is saved or removed.
    func setActive(_ active: Bool) {}
}
