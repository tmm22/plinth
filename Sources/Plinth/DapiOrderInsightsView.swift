import SwiftUI

// Views for the read-only 3DAPI order tools. PLACEHOLDER for the shared interface: the insights implementer replaces
// the bodies, keeping these names and initialisers, which the 3DAPI Orders section embeds.

/// The order detail's extra sections: attention reason, Profit check, Report a Problem.
struct DapiOrderInsightsSection: View {
    let order: DapiOrder
    var body: some View { EmptyView() }
}

/// The Orders toolbar's Tools menu for 3DAPI: Spending Report…, Export Orders…, Tracking for Your Shop….
struct DapiOrdersToolsMenu: View {
    /// The orders loaded in the list (every page read so far).
    let orders: [DapiOrder]
    var body: some View { EmptyView() }
}
