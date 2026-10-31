import SwiftUI

// The Orders section when 3DAPI is the print service. PLACEHOLDER for the shared interface: the orders implementer
// replaces this file (list, detail, composer, place-order review, cancel review).

/// Shown by `StudioView` for `.orders` while `PrintServiceChoice.shared.service == .dapi`.
struct DapiOrdersView: View {
    var body: some View {
        ContentUnavailableView("3DAPI orders", systemImage: "shippingbox")
    }
}
