import SwiftUI
import AppKit

// MARK: - Orders: "Since you last looked"

/// Names the order updates notice in its buttons' accessibility labels ("Dismiss Order Updates Notice").
let orderWatchNoticeAccessibilityName = "Order Updates Notice"
/// The banner's Show Changes: it refreshes the list and focuses it on the changed orders (it doesn't reveal the notice),
/// so its spoken name starts with the visible title and says which changes.
let orderWatchShowChangesTitle = "Show Changes"
let orderWatchShowChangesAccessibilityLabel = "Show Changes, order updates"

/// Above the orders list while checks have found changes the seller hasn't seen. Changes stay until Show Changes or Dismiss,
/// so glancing at Orders never loses them. Show Changes refreshes the newest orders (a user action, like Show All Orders) and
/// focuses the list on the changed ones.
struct OrderWatchBanner: View {
    @EnvironmentObject var store: StudioStore
    @ObservedObject private var watch = OrderWatch.shared
    let onShow: (_ ids: Set<String>) -> Void

    var body: some View {
        let changes = watch.unseenChanges
        if !changes.isEmpty {
            let summary = orderWatchSummaryText(changes)
            StudioNoticeStrip(.information) {
                (Text("Since you last looked: ").fontWeight(.semibold) + Text(summary))
                    .font(.callout)
                    .lineLimit(2)
                    .help(summary)
            } buttons: {
                // Shipped orders have tracking to copy into the shop. Opens the local list only; nothing is sent.
                if orderWatchChangesIncludeShipped(changes) {
                    Button("Tracking for Your Shop…") { store.openShopFollowUpFromMenu() }
                        .disabled(store.orders.isEmpty)
                        .help(store.orders.isEmpty ? "Load orders first" : "Copy shipped orders’ tracking into Etsy or Shopify")
                }
                Button(orderWatchShowChangesTitle) { onShow(Set(changes.map(\.id))) }
                    .disabled(!store.hasKey || store.busy)
                    .help("Refresh the list and show only the orders that changed")
                    .accessibilityLabel(orderWatchShowChangesAccessibilityLabel)
                Button("Dismiss") { watch.acknowledge() }
                    .help("Mark these changes as seen")
                    .accessibilityLabel(studioNoticeButtonAccessibilityLabel("Dismiss", notice: orderWatchNoticeAccessibilityName))
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Since you last looked: \(summary)")
        }
    }
}

/// Under the banner while Show Changes has focused the list on changed orders.
struct OrderWatchFocusBar: View {
    let count: Int
    let onShowAll: () -> Void

    var body: some View {
        HStack {
            Text(orderWatchFocusCaption(count: count)).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Show All Orders", action: onShowAll)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

// MARK: - Settings › Advanced

/// Settings › Advanced › Order updates, while 3DAPI is the print service.
let orderWatchDapiServiceNote = "While 3DAPI is your print service, Plinth keeps checking your Slant orders as above, and the Dock count still shows Slant orders; the sidebar’s Orders badge shows 3DAPI orders. 3DAPI orders are checked every 4 minutes in memory only: nothing about them is saved on this Mac. Notifications from both use the switch above and show the order number and status only. Clicking a Slant notification asks before switching the print service to Slant 3D."

struct OrderWatchSettingsSection: View {
    @ObservedObject private var watch = OrderWatch.shared
    @ObservedObject private var printChoice = PrintServiceChoice.shared
    @State private var confirmForget = false

    var body: some View {
        Section {
            Toggle("Check orders while Plinth is open", isOn: $watch.enabled)
            Toggle("Notify me about order changes", isOn: Binding(get: { watch.notify }, set: { watch.setNotify($0) }))
                .disabled(!watch.enabled || watch.requestingPermission || !orderWatchNotificationsAvailable())
            Toggle("Show count on Dock icon", isOn: $watch.dockBadge)
                .disabled(!watch.enabled)
                .help("The Dock icon shows your Slant orders’ count, as Orders in the sidebar does while Slant 3D is the print service: payment problems, reviews, cancellations and shipments you haven’t looked at")
            if watch.notificationsDenied {
                HStack {
                    Text("Notifications are turned off for Plinth in System Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Notification Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            LabeledContent("Last checked") {
                if let date = watch.snapshot.updatedAt {
                    Text(date, format: .dateTime.day().month().hour().minute())
                } else {
                    Text("Not yet").foregroundStyle(.secondary)
                }
            }
            // A refused key (401/403) or Slant's rate limit (429) holds checks back; Activity may be hidden.
            if watch.enabled, let caption = orderWatchHoldCaption(watch.hold, now: Date()) {
                Label(caption, systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if printChoice.service == .dapi {
                Label(orderWatchDapiServiceNote, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Forget Saved Statuses…") { confirmForget = true }
                .disabled(watch.snapshot.orders.isEmpty)
        } header: {
            Text("Order updates")
        } footer: {
            Text("Every few minutes, Plinth reads your newest and most recently updated orders and lists status changes to those on the default platform in Orders. Only each order’s ID, status and when it was seen are saved on this Mac, and they’re forgotten when you change the default platform or disconnect. Notifications (an order shipped or was cancelled) show the order number and status, never customer details; clicking one opens the order.")
                .settingsFooterLayout()
        }
        .confirmationDialog("Forget saved order statuses?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget Statuses", role: .destructive) { watch.forgetSavedStatuses() }
            // Never the destructive button: Return keeps the statuses.
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("Unseen changes are cleared. The next check records your orders’ statuses again without reporting them as changes.")
        }
    }
}
