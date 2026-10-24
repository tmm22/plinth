import SwiftUI
import AppKit

// MARK: - Orders: "Since you last looked"

/// Above the orders list while checks have found changes the seller hasn't seen. Changes stay until Show or Dismiss,
/// so glancing at Orders never loses them. Show reloads the newest orders (a user action, like Show All Orders) and
/// focuses the list on the changed ones.
struct OrderWatchBanner: View {
    @EnvironmentObject var store: StudioStore
    @ObservedObject private var watch = OrderWatch.shared
    let onShow: (_ ids: Set<String>) -> Void

    var body: some View {
        let changes = watch.unseenChanges
        if !changes.isEmpty {
            let summary = orderWatchSummaryText(changes)
            HStack(spacing: 10) {
                Image(systemName: "bell.badge")
                    .foregroundStyle(Color.studioAccent)
                    .accessibilityHidden(true)
                (Text("Since you last looked: ").fontWeight(.semibold) + Text(summary))
                    .font(.callout)
                    .lineLimit(2)
                    .help(summary)
                Spacer(minLength: 8)
                // Shipped orders have tracking to copy into the shop. Opens the local list only; nothing is sent.
                if orderWatchChangesIncludeShipped(changes) {
                    Button("Tracking for Your Shop…") { store.openShopFollowUpFromMenu() }
                        .buttonStyle(.link)
                        .disabled(store.orders.isEmpty)
                        .help(store.orders.isEmpty ? "Load orders first" : "Copy shipped orders’ tracking into Etsy or Shopify")
                }
                Button("Show") { onShow(Set(changes.map(\.id))) }
                    .disabled(!store.hasKey || store.busy)
                    .help("Reload the newest orders and list the ones that changed")
                Button("Dismiss") { watch.acknowledge() }
                    .help("Mark these changes as seen")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.studioAccent.opacity(0.08))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Since you last looked: \(summary)")
        }
    }
}

/// Under the banner while Show has focused the list on changed orders.
struct OrderWatchFocusBar: View {
    let count: Int
    let onShowAll: () -> Void

    var body: some View {
        HStack {
            Text(orderWatchFocusCaption(count: count)).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Show All Orders", action: onShowAll).controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

// MARK: - Settings › Advanced

struct OrderWatchSettingsSection: View {
    @ObservedObject private var watch = OrderWatch.shared
    @State private var confirmForget = false

    var body: some View {
        Section {
            Toggle("Check orders while Slant Studio is open", isOn: $watch.enabled)
            Toggle("Notify me about order changes", isOn: Binding(get: { watch.notify }, set: { watch.setNotify($0) }))
                .disabled(!watch.enabled || watch.requestingPermission || !orderWatchNotificationsAvailable())
            Toggle("Show count on Dock icon", isOn: $watch.dockBadge)
                .disabled(!watch.enabled)
                .help("The Dock icon shows the same count as Orders in the sidebar: payment problems, reviews, cancellations and shipments you haven’t looked at")
            if watch.notificationsDenied {
                HStack {
                    Text("Notifications are turned off for Slant Studio in System Settings.")
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
            Button("Forget Saved Statuses…") { confirmForget = true }
                .disabled(watch.snapshot.orders.isEmpty)
        } header: {
            Text("Order updates")
        } footer: {
            Text("Every few minutes, Studio reads your newest and most recently updated orders on the default platform and lists status changes in Orders. Only each order’s ID, status and when it was seen are saved on this Mac, and they’re forgotten when you change the default platform or disconnect. Notifications (shipped, delivered, cancelled, in review or a payment problem) show the order number and status, never customer details; clicking one opens the order.")
                .settingsFooterLayout()
        }
        .confirmationDialog("Forget saved order statuses?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget Statuses", role: .destructive) { watch.forgetSavedStatuses() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unseen changes are cleared. The next check records your orders’ statuses again without reporting them as changes.")
        }
    }
}
