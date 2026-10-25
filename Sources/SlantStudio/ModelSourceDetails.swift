import SwiftUI

// Who made a 3MF model and on what terms, from its model-level metadata. Display-only and advisory: nothing here is
// sent to Slant or used to block anything. The only thing saved is a copy of these four lines on an STL copy made from
// such a model (`LocalModel.sourceDetails` in models.json), so its licence still shows once the 3MF's own metadata is gone.
//
// Names read (case-insensitive, unprefixed):
// - 3MF Core Specification §3.4.1, Table 3-1: Designer, Copyright, LicenseTerms.
// - Bambu Studio and its forks (OrcaSlicer), which also write MakerWorld details (src/libslic3r/Format/bbs_3mf.cpp):
//   Designer, License, Origin, Copyright and the older CopyRight. Bambu escapes these values once more before writing
//   them, so one extra level of XML escaping is undone for display.
// PrusaSlicer writes the core names. Printables and Thingiverse serve the designer's own file, so whatever their
// exporter wrote is what is shown.

struct ModelSourceDetails: Equatable, Sendable, Codable {
    var designer: String?
    var licence: String?
    var source: String?
    var copyright: String?

    init(designer: String? = nil, licence: String? = nil, source: String? = nil, copyright: String? = nil) {
        self.designer = designer
        self.licence = licence
        self.source = source
        self.copyright = copyright
    }

    private enum CodingKeys: String, CodingKey { case designer, licence, source, copyright }

    /// Lenient: never throws, so a damaged entry can't stop models.json loading. Anything that isn't a string is
    /// dropped, and each value is made one safe line again (without undoing XML escaping a second time).
    init(from decoder: Decoder) {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        func field(_ key: CodingKeys) -> String? {
            (try? container?.decodeIfPresent(String.self, forKey: key))
                .flatMap { sanitisedMetadataValue($0, unescapingXML: false) }
        }
        self.init(designer: field(.designer), licence: field(.licence), source: field(.source), copyright: field(.copyright))
    }

    var isEmpty: Bool { designer == nil && licence == nil && source == nil && copyright == nil }

    /// Label/value rows for the inspector, in display order.
    var rows: [(label: String, value: String)] {
        [("Designer", designer), ("Licence", licence), ("Source", source), ("Copyright", copyright)]
            .compactMap { row in row.1.map { (row.0, $0) } }
    }
}

/// Characters shown per field; longer values end with an ellipsis.
let modelSourceFieldLimit = 200

/// Builds the details from metadata entries in document order. The first usable value of each field wins; the core
/// `LicenseTerms` is preferred over Bambu's `License` wherever they appear.
func modelSourceDetails(fromMetadata entries: [(name: String, value: String)]) -> ModelSourceDetails {
    var details = ModelSourceDetails()
    var bambuLicence: String?
    for entry in entries {
        guard let value = sanitisedMetadataValue(entry.value) else { continue }
        switch entry.name.lowercased() {
        case "designer": if details.designer == nil { details.designer = value }
        case "licenseterms": if details.licence == nil { details.licence = value }
        case "license": if bambuLicence == nil { bambuLicence = value }
        case "origin": if details.source == nil { details.source = value }
        case "copyright": if details.copyright == nil { details.copyright = value }
        default: break
        }
    }
    if details.licence == nil { details.licence = bambuLicence }
    return details
}

/// One line of plain text: one extra level of XML escaping undone (unless `unescapingXML` is false, for text that was
/// already cleaned), control, line-break and bidirectional-override characters replaced by spaces, whitespace
/// collapsed, and cut to `limit` characters. Nil when nothing is left.
func sanitisedMetadataValue(_ raw: String, limit: Int = modelSourceFieldLimit, unescapingXML: Bool = true) -> String? {
    var text = raw
    if unescapingXML, text.contains("&") {
        // &amp; last, so "&amp;lt;" becomes "&lt;" rather than "<".
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
    }
    let bidiControls = CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")
    let unsafe = CharacterSet.controlCharacters.union(.newlines).union(.illegalCharacters).union(bidiControls)
    let scalars = text.unicodeScalars.map { unsafe.contains($0) ? " " : String($0) }.joined()
    let words = scalars.split(whereSeparator: { $0.isWhitespace })
    guard !words.isEmpty else { return nil }
    let line = words.joined(separator: " ")
    guard line.count > limit else { return line }
    return String(line.prefix(max(limit - 1, 0))).trimmingCharacters(in: .whitespaces) + "…"
}

// MARK: - Licence check

enum ModelLicenceConcern: Equatable {
    /// Creative Commons NC, "non-commercial", "personal use only", or a platform's personal-use licence.
    case nonCommercial
    /// Creative Commons ND or "no derivatives": changed versions may not be shared.
    case noDerivatives
}

/// What the licence (or copyright) text appears to restrict. Text matching only, so it can miss unusual wording and
/// is never treated as legal advice.
func modelLicenceConcerns(_ text: String) -> [ModelLicenceConcern] {
    let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    let tokens = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    guard !tokens.isEmpty else { return [] }
    let joined = " " + tokens.joined(separator: " ") + " "
    func has(_ phrase: String) -> Bool { joined.contains(" \(phrase) ") }
    // A bare "NC" or "ND" only counts as part of a Creative Commons code ("CC BY-NC-SA", Bambu's "BY-ND"), so
    // "Raleigh, NC" isn't read as a licence term.
    func inLicenceCode(_ term: String) -> Bool {
        let codeParts: Set<String> = ["cc", "by", "nc", "nd", "sa"]
        return tokens.indices.contains { tokens[$0] == term && $0 > 0 && codeParts.contains(tokens[$0 - 1]) }
    }
    var concerns: [ModelLicenceConcern] = []
    let nonCommercialPhrases = [
        "noncommercial", "non commercial", "no commercial use", "not for commercial", "not for commercial use",
        "commercial use not", "commercial use is not", "commercial use prohibited", "commercial use is prohibited",
        "commercial use forbidden", "commercial use is forbidden", "personal use only", "for personal use only",
        "only for personal use", "private use only", "standard digital file license", "standard digital file licence"
    ]
    if inLicenceCode("nc") || nonCommercialPhrases.contains(where: has) {
        concerns.append(.nonCommercial)
    }
    let noDerivativePhrases = ["noderivatives", "noderivs", "no derivatives", "no derivative works", "no derivs"]
    if inLicenceCode("nd") || noDerivativePhrases.contains(where: has) {
        concerns.append(.noDerivatives)
    }
    return concerns
}

let modelLicenceAdvisoryText = "This licence may not allow selling prints. Check before listing."

/// The orange advisory, or nil. Non-commercial terms always count; no-derivatives terms count only for a copy Studio
/// changed (`edited`), since prints of the unchanged model aren't a derivative. Licence and copyright are both read,
/// because some designers put the licence in the copyright line.
func modelLicenceAdvisory(_ details: ModelSourceDetails, edited: Bool) -> String? {
    let text = [details.licence, details.copyright].compactMap { $0 }.joined(separator: " ")
    let concerns = modelLicenceConcerns(text)
    guard concerns.contains(.nonCommercial) || (edited && concerns.contains(.noDerivatives)) else { return nil }
    return modelLicenceAdvisoryText
}

/// The details to show and check for a library model: the file's own (a 3MF's metadata) when it has any, otherwise
/// those carried over from the model an STL copy was made from.
func modelSourceDetailsToShow(stored: ModelSourceDetails?, fromFile: ModelSourceDetails) -> ModelSourceDetails {
    fromFile.isEmpty ? (stored ?? ModelSourceDetails()) : fromFile
}

/// What a new STL copy saves: the details of the model it was made from, or nil when there are none.
func sourceDetailsForCopy(of model: LocalModel, fromFile: ModelSourceDetails = ModelSourceDetails()) -> ModelSourceDetails? {
    let details = modelSourceDetailsToShow(stored: model.sourceDetails, fromFile: fromFile)
    return details.isEmpty ? nil : details
}

/// True for a library copy one of the Improve for printing tools changed.
func modelIsEditedCopy(_ model: LocalModel) -> Bool {
    model.printRecipe != nil || model.designImprovement != nil || model.reinforcement != nil || model.autoImprovement != nil
        || model.printPreparation != nil
}

// MARK: - Inspector panel

/// Shown under the mesh check when a 3MF names its designer, licence, source or copyright. Values are plain,
/// selectable text: a link in the metadata is never opened or made clickable.
struct ModelSourceDetailsPanel: View {
    let details: ModelSourceDetails
    let edited: Bool
    /// True when the details came from the model this copy was made from, not from this file.
    var inherited = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Source and licence").font(.callout.weight(.semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(details.rows, id: \.label) { row in
                    GridRow {
                        Text(row.label).font(.callout).foregroundStyle(.secondary)
                        Text(verbatim: row.value)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if let advisory = modelLicenceAdvisory(details, edited: edited) {
                Label(advisory, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(inherited ? "From the original file’s details, as its creator or exporter wrote them. This copy keeps them for reference."
                           : "From the file’s own details, as its creator or exporter wrote them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
