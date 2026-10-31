import Foundation
import SwiftUI

// Which print service the seller works with: Slant 3D (the default, everything Plinth has always done) or 3DAPI
// (dapi.digital), which offers the same workflows where its API allows. The choice is the only new preference; the
// services never share data (no Slant price, ID or file reaches 3DAPI, and none of 3DAPI's reaches Slant).

/// The print service the Models next-action bar, the Orders section and Catalog's materials work with.
enum PrintService: String, CaseIterable, Identifiable, Sendable {
    case slant
    case dapi

    var id: String { rawValue }

    /// The service's name in copy ("Slant 3D", "3DAPI").
    var displayName: String {
        switch self {
        case .slant: "Slant 3D"
        case .dapi: "3DAPI"
        }
    }

    /// The UserDefaults key holding the raw value; absent or unknown means Slant.
    static let defaultsKey = "printService"

    /// The saved choice, Slant when none is saved or the saved value is unknown.
    static func saved(in defaults: UserDefaults = .standard) -> PrintService {
        defaults.string(forKey: defaultsKey).flatMap(PrintService.init(rawValue:)) ?? .slant
    }
}

/// The seller's current print service, shared by the main window and Settings. Changing it is refused while either
/// service has a write waiting for its reply or an order sheet is open (`changeBlockedReason`, filled in by the
/// Settings implementation), so a running order never loses the screen that reports its outcome.
@MainActor final class PrintServiceChoice: ObservableObject {
    static let shared = PrintServiceChoice()

    @Published private(set) var service: PrintService
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        service = PrintService.saved(in: defaults)
    }

    /// Switches to `service` unless `blockedReason` (computed by the caller from both services' state) says why not;
    /// returns that reason, or nil once switched.
    @discardableResult
    func select(_ service: PrintService, blockedReason: String?) -> String? {
        guard service != self.service else { return nil }
        if let blockedReason { return blockedReason }
        self.service = service
        defaults.set(service.rawValue, forKey: PrintService.defaultsKey)
        return nil
    }
}
