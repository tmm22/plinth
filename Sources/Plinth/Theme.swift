import SwiftUI
import AppKit

// MARK: - Palette

/// An sRGB colour in 0–255 components, so the palette's contrast can be checked by plain arithmetic in tests.
struct StudioRGB: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    var nsColor: NSColor { NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1) }
}

/// WCAG 2.2 relative luminance of an sRGB colour (0 for black, 1 for white).
func wcagRelativeLuminance(_ color: StudioRGB) -> Double {
    func channel(_ value: Double) -> Double {
        let c = value / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
}

/// WCAG 2.2 contrast ratio between two colours, from 1 (none) to 21 (black on white). 1.4.3 asks 4.5 for text, 1.4.11
/// asks 3 for icons and the parts of controls.
func wcagContrastRatio(_ first: StudioRGB, _ second: StudioRGB) -> Double {
    let a = wcagRelativeLuminance(first), b = wcagRelativeLuminance(second)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

/// `color` drawn at `opacity` over `background` (as a tinted capsule or notice strip is), in sRGB.
func wcagComposite(_ color: StudioRGB, opacity: Double, over background: StudioRGB) -> StudioRGB {
    StudioRGB(color.red * opacity + background.red * (1 - opacity),
              color.green * opacity + background.green * (1 - opacity),
              color.blue * opacity + background.blue * (1 - opacity))
}

/// The app's own colours in light and dark mode. `ThemeContrastTests` pins them (WCAG 1.4.3: 4.5:1 for text; 1.4.11:
/// 3:1 for icons), so a change can't drift below: the status colours as text on every background below, on their badge
/// tint and on the notice strip's; the accent as text on white and the window grey, as an icon on the sidebar grey, and
/// under white button text.
enum StudioPalette {
    /// The light accent: text on white and on the window grey, and white text on it (filled buttons), at least 4.5:1.
    static let accentLight = StudioRGB(190, 64, 6)
    /// The dark accent: as text on the dark window at least 4.5:1, and white text on it at least 3.5:1, about what
    /// Apple's own dark-mode blue gives. One orange can't reach 4.5:1 both as text on a dark window and under white
    /// text, so filled buttons get the lower figure in dark mode, as system buttons do.
    static let accentDark = StudioRGB(220, 98, 22)
    /// Text on an accent-tinted badge ("Default", catalogue prices): the accent itself reaches only about 3.5–4.3:1 on
    /// its own tint, so the badge's text is a deeper orange (light) or a lighter one (dark), its tint unchanged.
    static let accentBadgeTextLight = StudioRGB(150, 50, 4)
    static let accentBadgeTextDark = StudioRGB(250, 150, 90)
    /// Warnings (amber/orange), successes (green) and errors (red) as text, icons and badge text.
    static let warningLight = StudioRGB(146, 64, 4)
    static let warningDark = StudioRGB(245, 158, 11)
    static let successLight = StudioRGB(18, 100, 44)
    static let successDark = StudioRGB(60, 210, 100)
    static let errorLight = StudioRGB(170, 28, 28)
    static let errorDark = StudioRGB(255, 150, 140)

    /// What the colours are checked against: white, the window and grouped-form grey, and the sidebar grey (light);
    /// the dark window, a dark grouped row and the dark sidebar (dark).
    static let lightBackgrounds = [StudioRGB(255, 255, 255), StudioRGB(236, 236, 236), StudioRGB(229, 229, 229)]
    static let darkBackgrounds = [StudioRGB(30, 30, 30), StudioRGB(45, 45, 45), StudioRGB(50, 50, 50)]
    /// `StudioBadge`'s tint behind its text, and the warning notice strip's.
    static let badgeTintOpacity = 0.14
    static let noticeTintOpacity = 0.08
}

/// One colour for light mode and another for dark mode (including the high-contrast appearances).
private func studioDynamicColor(_ name: String, light: StudioRGB, dark: StudioRGB) -> Color {
    Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark.nsColor : light.nsColor
    })
}

private let studioWarningColor = studioDynamicColor("studioWarning", light: StudioPalette.warningLight, dark: StudioPalette.warningDark)
private let studioSuccessColor = studioDynamicColor("studioSuccess", light: StudioPalette.successLight, dark: StudioPalette.successDark)
private let studioErrorColor = studioDynamicColor("studioError", light: StudioPalette.errorLight, dark: StudioPalette.errorDark)
private let studioAccentBadgeTextColor = studioDynamicColor("studioAccentBadgeText", light: StudioPalette.accentBadgeTextLight,
                                                            dark: StudioPalette.accentBadgeTextDark)

extension Color {
    /// Slant 3D orange, deeper in light mode so text and glyphs, and white text on filled buttons, keep contrast.
    static let studioAccent = studioDynamicColor("studioAccent", light: StudioPalette.accentLight, dark: StudioPalette.accentDark)
    static let studioCanvas = Color(nsColor: .windowBackgroundColor)
    static let studioCard = Color(nsColor: .controlBackgroundColor)
    static let studioHairline = Color.primary.opacity(0.08)
}

/// Readable replacements for the system `.orange`, `.green` and `.red`, which are too faint as text on a light window
/// (about 2:1). They work wherever those do: `.foregroundStyle(.studioWarning)`, `.tint(.studioError)`,
/// `Color.studioSuccess.opacity(0.1)`.
extension ShapeStyle where Self == Color {
    static var studioWarning: Color { studioWarningColor }
    static var studioSuccess: Color { studioSuccessColor }
    static var studioError: Color { studioErrorColor }
}

enum StudioMetrics {
    static let pagePadding: CGFloat = 24
    static let cardPadding: CGFloat = 20
    static let cardRadius: CGFloat = 12
    static let tileRadius: CGFloat = 8
}

// MARK: - Building blocks

struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(StudioMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.studioCard, in: RoundedRectangle(cornerRadius: StudioMetrics.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: StudioMetrics.cardRadius).stroke(Color.studioHairline))
    }
}

struct SectionHeading: View {
    let title: String
    var caption: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if !caption.isEmpty { Text(caption).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct StudioBadge: View {
    enum Tone { case neutral, accent, success, warning }
    let text: String
    var tone: Tone = .neutral
    /// `.increased` on a selected (accent-filled) list row, where tinted text on a tinted capsule loses contrast.
    @Environment(\.backgroundProminence) private var backgroundProminence

    private var color: Color {
        switch tone {
        case .neutral: .secondary
        case .accent: .studioAccent
        case .success: .studioSuccess
        case .warning: .studioWarning
        }
    }

    /// The text colour: the tone's colour, except the accent, whose own tint needs a deeper text colour.
    private var textColor: Color { tone == .accent ? studioAccentBadgeTextColor : color }

    var body: some View {
        let onSelection = studioBadgeUsesSelectedStyle(backgroundProminence)
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(onSelection ? Color.white : textColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(onSelection ? Color.white.opacity(0.22) : color.opacity(0.14), in: Capsule())
    }
}

/// Badges switch to white text on a translucent white capsule when their row's background is prominent (selected).
func studioBadgeUsesSelectedStyle(_ prominence: BackgroundProminence) -> Bool {
    prominence == .increased
}

/// Square thumbnail used for every list row and catalogue card, so items share one silhouette.
struct StudioTile: View {
    let symbol: String
    var imageURL: URL? = nil
    var fill: Color? = nil
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: StudioMetrics.tileRadius)
                .fill(fill ?? Color.studioAccent.opacity(0.12))
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit().padding(size * 0.08)
                    } else {
                        glyph
                    }
                }
            } else if fill == nil {
                glyph
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: StudioMetrics.tileRadius))
        .overlay(RoundedRectangle(cornerRadius: StudioMetrics.tileRadius).stroke(Color.studioHairline))
        .accessibilityHidden(true)
    }

    private var glyph: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(Color.studioAccent)
    }
}

/// Toolbar-sized primary action shared by every page so the main call to action always looks the same.
struct PrimaryToolbarButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderedProminent)
    }
}

// MARK: - Notices

/// A notice strip's kind: a warning (amber triangle on an amber tint) or information (accent "i" on a neutral tint).
enum StudioNoticeKind {
    case warning, information

    var symbol: String { self == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill" }
    var iconColor: Color { self == .warning ? .studioWarning : .studioAccent }
    var background: Color {
        self == .warning ? Color.studioWarning.opacity(StudioPalette.noticeTintOpacity) : Color.primary.opacity(0.04)
    }
}

/// The accessibility label of a notice's button: the visible title first (so Voice Control's "Click Dismiss" still
/// works), then which notice it belongs to, because several notices can show at once with the same button titles.
func studioNoticeButtonAccessibilityLabel(_ visibleTitle: String, notice: String) -> String {
    "\(visibleTitle) \(notice)"
}

/// The one look for the main window's notices (Orders' order updates and Slant API change, the saved products' material
/// notice and the migration notices): a full-width strip with an icon, the message and trailing buttons, and a hairline
/// below so stacked notices stay apart. Callers keep their own text, conditions and button actions.
struct StudioNoticeStrip<Message: View, Buttons: View>: View {
    let kind: StudioNoticeKind
    @ViewBuilder let message: () -> Message
    @ViewBuilder let buttons: () -> Buttons

    init(_ kind: StudioNoticeKind, @ViewBuilder message: @escaping () -> Message,
         @ViewBuilder buttons: @escaping () -> Buttons) {
        self.kind = kind
        self.message = message
        self.buttons = buttons
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.iconColor)
                .accessibilityHidden(true)
            message()
                .frame(maxWidth: .infinity, alignment: .leading)
            // The buttons keep their size; the message wraps instead.
            HStack(spacing: 8) { buttons() }
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.background)
        .overlay(alignment: .bottom) { Divider() }
    }
}
