import SwiftUI

/// Whether the main window shows the saved products' material notice on this screen. Saved Products are a Slant
/// feature: with 3DAPI as the print service nothing is shown (Slant's materials never apply to 3DAPI), and the
/// developer screens are left alone.
func savedProductStockNoticeScreen(destination: Destination, service: PrintService) -> Bool {
    guard service == .slant else { return false }
    switch destination {
    case .api, .activity: return false
    default: return true
    }
}

/// At the top of the main window when a saved product can't be ordered because a material is out of stock or no
/// longer offered (MaterialStock.swift). Advice only: no default button, nothing sent, nothing changed; Open Saved
/// Products… only opens the sheet, and Dismiss hides it until another product or material is affected.
struct SavedProductStockNotice: View {
    @EnvironmentObject var store: StudioStore
    @ObservedObject private var watch = MaterialStockWatch.shared
    @ObservedObject private var printChoice = PrintServiceChoice.shared

    private var materials: (records: [Record], at: Date?) { watch.materials(for: store) }
    private var check: SavedProductStockCheck {
        guard printChoice.service == .slant else { return .notChecked }
        return savedProductStockCheck(products: store.savedProducts, filaments: materials.records)
    }

    var body: some View {
        let check = check
        let issues = check.issues
        let pairs = savedProductStockPairs(issues)
        let shown = savedProductStockNoticeScreen(destination: store.destination, service: printChoice.service)
            && savedProductStockNoticeVisible(current: pairs, dismissed: watch.dismissed)
        // A VStack (never an empty Group) so the dismissal is kept up to date even while nothing is shown.
        VStack(spacing: 0) {
            if shown, let headline = savedProductStockNoticeHeadline(issues) {
                let lines = [headline, savedProductStockNoticeMaterialsLine(issues),
                             savedProductStockNoticeAdvice(count: issues.count, materialsAt: materials.at)].compactMap { $0 }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(lines[0]).font(.callout)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(lines.dropFirst(), id: \.self) { line in
                            Text(line).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    Button("Open Saved Products…") { store.openSavedProducts() }
                        .help("See and edit your saved products. Nothing is changed or sent.")
                    Button("Dismiss") { watch.dismiss(pairs) }
                        .help("Hide this until another saved product or material is affected")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.08))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(lines.joined(separator: " "))
            }
        }
        // Only a real check narrows the dismissal; "not checked" (materials not loaded yet) leaves it as it is.
        .onChange(of: check, initial: true) { _, new in watch.noteCheck(new) }
    }
}
