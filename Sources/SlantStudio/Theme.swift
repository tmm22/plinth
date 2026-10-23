import SwiftUI
import AppKit

// MARK: - Palette

extension Color {
    /// Slant 3D orange. Slightly deeper in light mode so text and glyphs keep contrast on white.
    static let studioAccent = Color(nsColor: NSColor(name: "studioAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.984, green: 0.573, blue: 0.235, alpha: 1)
            : NSColor(srgbRed: 0.918, green: 0.345, blue: 0.047, alpha: 1)
    })
    static let studioCanvas = Color(nsColor: .windowBackgroundColor)
    static let studioCard = Color(nsColor: .controlBackgroundColor)
    static let studioHairline = Color.primary.opacity(0.08)
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
        case .success: .green
        case .warning: .orange
        }
    }

    var body: some View {
        let onSelection = studioBadgeUsesSelectedStyle(backgroundProminence)
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(onSelection ? Color.white : color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(onSelection ? Color.white.opacity(0.22) : color.opacity(0.14), in: Capsule())
    }
}

/// Badges switch to white text on a translucent white capsule when their row's background is prominent (selected).
func studioBadgeUsesSelectedStyle(_ prominence: BackgroundProminence) -> Bool {
    prominence == .increased
}

/// Square thumbnail used for every list row and catalog card, so items share one silhouette.
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
