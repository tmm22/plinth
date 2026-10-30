import SwiftUI

// MARK: - Orders: Slant changed its API

/// Above the orders list when Slant's public API description differs from the one this version was made for, or a
/// reply had an order status Studio doesn't recognise or couldn't be read. Non-modal; Details… opens Settings ›
/// Advanced, Dismiss hides it until something new is noticed. It changes nothing about how Studio behaves.
struct SlantAPIChangeNotice: View {
    @EnvironmentObject var store: StudioStore
    @ObservedObject private var watch = SlantAPIWatch.shared

    var body: some View {
        let lines = watch.noticeLines
        if !lines.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(lines, id: \.self) { line in
                        Text(line)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Button("Details…") { store.requestSettings(.advanced) }
                    .help("Open Settings › Advanced › Slant API")
                Button("Dismiss") { watch.dismissNotice() }
                    .help("Hide this until Plinth notices another change")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.08))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(lines.joined(separator: " "))
        }
    }
}

// MARK: - Settings › Advanced › Slant API

struct SlantAPISettingsSection: View {
    @ObservedObject private var watch = SlantAPIWatch.shared

    var body: some View {
        Section {
            Text(slantAPISettingsStateText(record: watch.record, bundleAvailable: watch.bundleAvailable))
                .fixedSize(horizontal: false, vertical: true)
            if let difference = watch.lastDifference, !difference.isEmpty {
                Text(slantAPIChangedOperationsText(difference))
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("Last checked") {
                if let date = watch.record.checkedAt {
                    Text(date, format: .dateTime.day().month().hour().minute())
                } else {
                    Text("Not yet").foregroundStyle(.secondary)
                }
            }
            if let failure = watch.lastFailure, let at = watch.lastFailureAt {
                Label("Couldn’t check at \(at.formatted(date: .omitted, time: .shortened)): \(slantAPIFetchErrorText(failure)).",
                      systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("Unrecognised order statuses") {
                if watch.signals.statuses.isEmpty {
                    Text("None this session").foregroundStyle(.secondary)
                } else {
                    Text(watch.signals.statuses.joined(separator: ", ") + (watch.signals.moreStatuses ? " and others" : ""))
                        .textSelection(.enabled)
                }
            }
            if watch.signals.unreadableOrderLists > 0 {
                LabeledContent("Unreadable order lists") { Text("\(watch.signals.unreadableOrderLists) this session") }
            }
            HStack {
                Button("Check Now") { watch.checkNow() }
                    .disabled(watch.checking || !watch.bundleAvailable)
                if watch.checking { ProgressView().controlSize(.small) }
            }
        } header: {
            Text("Slant API")
        } footer: {
            Text("Once a day while a Slant account is connected, Plinth downloads Slant’s public API description, without your key or any account details, and compares it with the one this version was made for. It also notes order statuses it doesn’t recognise in Slant’s replies this session. Plinth never changes how it works because of these checks; it only tells you. Only these are saved: when it last checked, the labels Slant gives its description (so an unchanged one isn’t downloaded again), the names of the changed areas, fingerprints of the public API description and of the one Plinth was made for, and what you dismissed, including any status words.")
                .settingsFooterLayout()
        }
    }
}

/// "Changed operations: GET /orders, POST /orders · definitions: Order", capped so the section stays short.
func slantAPIChangedOperationsText(_ difference: SlantAPIDifference, limit: Int = 8) -> String {
    func capped(_ items: [String]) -> String {
        items.count > limit ? items.prefix(limit).joined(separator: ", ") + " and \(items.count - limit) more" : items.joined(separator: ", ")
    }
    var parts: [String] = []
    if !difference.operations.isEmpty { parts.append("Changed operations: " + capped(difference.operations)) }
    if !difference.definitions.isEmpty { parts.append("definitions: " + capped(difference.definitions)) }
    if difference.general { parts.append("servers, security or version") }
    let text = parts.joined(separator: " · ")
    return text.prefix(1).uppercased() + text.dropFirst()
}
