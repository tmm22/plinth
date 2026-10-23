import SwiftUI

/// Every disclosure in the app: the chevron and the label are one full-width button, so clicking the label text (not
/// only the small triangle) expands it, and VoiceOver hears the label, "button" and the expanded state rather than an
/// unnamed "disclosure triangle". Applied once at the root of each window scene (`studioDisclosureStyle()`); sheets
/// inherit it from the view that presents them.
///
/// Labels must stay non-interactive (text, `Label`, `SectionHeading`): a control inside the label would sit inside
/// this button.
struct StudioDisclosureGroupStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: disclosureChevronWidth)
                        .accessibilityHidden(true)
                    configuration.label
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(disclosureAccessibilityValue(isExpanded: configuration.isExpanded))
            .accessibilityHint(disclosureAccessibilityHint(isExpanded: configuration.isExpanded))

            if configuration.isExpanded {
                configuration.content
                    .padding(.leading, disclosureChevronWidth + 6)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
    }
}

private let disclosureChevronWidth: CGFloat = 12

/// Spoken after the label, e.g. "Advanced, button, collapsed".
func disclosureAccessibilityValue(isExpanded: Bool) -> String {
    isExpanded ? "Expanded" : "Collapsed"
}

func disclosureAccessibilityHint(isExpanded: Bool) -> String {
    isExpanded ? "Hides the details." : "Shows the details."
}

extension View {
    /// Sets `StudioDisclosureGroupStyle` for every disclosure below, including sheets presented from here.
    func studioDisclosureStyle() -> some View {
        disclosureGroupStyle(StudioDisclosureGroupStyle())
    }
}
