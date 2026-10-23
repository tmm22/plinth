import Foundation
import AppKit
import UniformTypeIdentifiers

// Personalise from Template: fills in an OpenSCAD template's Customizer values (a buyer's name on a keychain, say) and
// generates an STL, either with OpenSCAD installed on this Mac or with Slant's `POST /files/openScad`. The result is
// checked like any STL and saved as a new library model; nothing is uploaded. Values typed here (often a customer's
// name) stay in the sheet's memory; they reach disk only inside the generated STL and the new model's name.

// MARK: Template parameters

enum ScadValueKind: Equatable {
    case string, number, boolean
}

struct ScadChoice: Equatable {
    /// The value as entered in the template's comment: text for strings, number text for numbers.
    let value: String
    let label: String
}

struct ScadParameter: Equatable, Identifiable {
    var id: String { name }
    let name: String
    let kind: ScadValueKind
    /// Decoded default: the text of a string, a number as written, or `true`/`false`.
    var defaultValue: String
    /// The `//` comment on the line above (OpenSCAD Customizer's description).
    var description: String?
    /// The `/* [Group] */` section it sits in, if any.
    var group: String?
    /// Customizer drop-down values (`// [a, b, c]` or `// [10:Small, 20:Large]`).
    var choices: [ScadChoice] = []
    /// Customizer slider range for numbers (`// [0:100]` or `// [0:5:100]`).
    var range: ClosedRange<Double>?
    /// Customizer text-box limit for strings (`// 8`).
    var maxLength: Int?
    /// 1-based line number in the template.
    let line: Int
}

struct ScadTemplate: Equatable {
    var parameters: [ScadParameter] = []
    /// The template has `include <…>` or `use <…>`, which Slant can't resolve (it receives only this file's text).
    var usesOtherFiles = false
    /// False when the file ends inside a block comment, a string or an open bracket, so values appended to it for Slant
    /// wouldn't be read as assignments.
    var endsCleanly = true
}

/// Line-crossing scanner state for a .scad file.
struct ScadScanState {
    var inBlockComment = false
    var blockText = ""
    var inString = false
    var depth = 0
}

struct ScadLineParts {
    var code = ""
    var lineComment: String?
    var blockComments: [String] = []
}

/// Splits one line into code (strings kept intact) and comments, updating the block-comment, string and bracket state.
func scadScanLine(_ line: String, state: inout ScadScanState) -> ScadLineParts {
    var parts = ScadLineParts()
    let chars = Array(line)
    var index = 0
    while index < chars.count {
        let char = chars[index]
        let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
        if state.inBlockComment {
            if char == "*", next == "/" {
                state.inBlockComment = false
                parts.blockComments.append(state.blockText)
                state.blockText = ""
                index += 2
            } else {
                if state.blockText.count < 10_000 { state.blockText.append(char) }
                index += 1
            }
            continue
        }
        if state.inString {
            parts.code.append(char)
            if char == "\\", let next {
                parts.code.append(next)
                index += 2
                continue
            }
            if char == "\"" { state.inString = false }
            index += 1
            continue
        }
        if char == "/", next == "/" {
            parts.lineComment = String(chars[(index + 2)...])
            break
        }
        if char == "/", next == "*" {
            state.inBlockComment = true
            state.blockText = ""
            index += 2
            continue
        }
        switch char {
        case "\"": state.inString = true
        case "{", "[", "(": state.depth += 1
        case "}", "]", ")": state.depth = max(0, state.depth - 1)
        default: break
        }
        parts.code.append(char)
        index += 1
    }
    // A block comment still open at the end of the line keeps its text so far; a line break inside it is a space.
    if state.inBlockComment, !state.blockText.isEmpty { state.blockText.append(" ") }
    return parts
}

enum ScadLiteral: Equatable {
    case string(String)
    case number(String)
    case boolean(Bool)
}

/// Strict OpenSCAD number syntax: an optional minus, digits with an optional fraction, and an optional exponent.
func scadIsNumberLiteral(_ text: String) -> Bool {
    text.range(of: #"^-?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)(?:[eE][-+]?[0-9]+)?$"#, options: .regularExpression) != nil
        && Double(text)?.isFinite == true
}

/// Decodes an OpenSCAD string literal starting at `chars[start]` (the opening quote). Returns the text and the index
/// after the closing quote, or nil when the string doesn't close.
func scadDecodeString(_ chars: [Character], from start: Int) -> (text: String, end: Int)? {
    guard start < chars.count, chars[start] == "\"" else { return nil }
    var text = ""
    var index = start + 1
    func hexScalar(_ count: Int) -> Unicode.Scalar? {
        guard index + count < chars.count else { return nil }
        let digits = String(chars[(index + 1)...(index + count)])
        guard digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        return Unicode.Scalar(value)
    }
    while index < chars.count {
        let char = chars[index]
        if char == "\"" { return (text, index + 1) }
        if char == "\\", index + 1 < chars.count {
            let escape = chars[index + 1]
            switch escape {
            case "\"": text.append("\""); index += 2
            case "\\": text.append("\\"); index += 2
            case "n": text.append("\n"); index += 2
            case "t": text.append("\t"); index += 2
            case "r": text.append("\r"); index += 2
            case "x":
                index += 1
                if let scalar = hexScalar(2), (1...0x7F).contains(scalar.value) {
                    text.unicodeScalars.append(scalar); index += 3
                } else { text.append("\\x"); index += 1 }
            case "u", "U":
                let count = escape == "u" ? 4 : 6
                index += 1
                if let scalar = hexScalar(count), scalar.value != 0 {
                    text.unicodeScalars.append(scalar); index += count + 1
                } else { text.append("\\"); text.append(escape); index += 1 }
            default:
                // OpenSCAD keeps an unknown escape as written.
                text.append("\\"); text.append(escape); index += 2
            }
            continue
        }
        text.append(char)
        index += 1
    }
    return nil
}

/// `name = literal;` with nothing else on the line's code, where the literal is a string, number or `true`/`false`.
/// Expressions, vectors and special `$` variables aren't customisable values.
func scadParseAssignment(_ code: String) -> (name: String, value: ScadLiteral)? {
    let chars = Array(code.trimmingCharacters(in: .whitespaces))
    var index = 0
    func skipSpaces() { while index < chars.count, chars[index].isWhitespace { index += 1 } }
    guard index < chars.count, chars[index].isASCII, chars[index].isLetter || chars[index] == "_" else { return nil }
    var name = ""
    while index < chars.count, chars[index].isASCII, chars[index].isLetter || chars[index].isNumber || chars[index] == "_" {
        name.append(chars[index]); index += 1
    }
    skipSpaces()
    guard index < chars.count, chars[index] == "=", index + 1 >= chars.count || chars[index + 1] != "=" else { return nil }
    index += 1
    skipSpaces()
    guard index < chars.count else { return nil }
    let value: ScadLiteral
    if chars[index] == "\"" {
        guard let decoded = scadDecodeString(chars, from: index) else { return nil }
        value = .string(decoded.text)
        index = decoded.end
    } else {
        var token = ""
        while index < chars.count, !chars[index].isWhitespace, chars[index] != ";" { token.append(chars[index]); index += 1 }
        if token == "true" { value = .boolean(true) }
        else if token == "false" { value = .boolean(false) }
        else if scadIsNumberLiteral(token) { value = .number(token) }
        else { return nil }
    }
    skipSpaces()
    guard index < chars.count, chars[index] == ";" else { return nil }
    index += 1
    skipSpaces()
    guard index == chars.count else { return nil }
    return (name, value)
}

enum ScadConstraint: Equatable {
    case choices([ScadChoice])
    case range(ClosedRange<Double>)
    case maxLength(Int)
}

/// Reads a Customizer trailing comment: `[a, b]` / `[1:Small, 2:Large]` drop-downs, `[min:max]` or `[min:step:max]`
/// number ranges, and a bare number limiting a string's length. Anything else is nil.
func scadConstraint(_ comment: String, kind: ScadValueKind) -> ScadConstraint? {
    let trimmed = comment.trimmingCharacters(in: .whitespaces)
    if kind == .string, let length = Int(trimmed), (1...10_000).contains(length) { return .maxLength(length) }
    guard kind != .boolean, trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count > 2 else { return nil }
    let inner = String(trimmed.dropFirst().dropLast())
    if kind == .number, !inner.contains(",") {
        let pieces = inner.split(separator: ":", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if (2...3).contains(pieces.count), pieces.allSatisfy(scadIsNumberLiteral),
           let low = Double(pieces[0]), let high = Double(pieces[pieces.count - 1]), low <= high {
            return .range(low...high)
        }
    }
    var choices: [ScadChoice] = []
    for item in inner.split(separator: ",", omittingEmptySubsequences: false).prefix(201) {
        let entry = item.trimmingCharacters(in: .whitespaces)
        var value = entry, label = entry
        if let colon = entry.firstIndex(of: ":") {
            value = entry[..<colon].trimmingCharacters(in: .whitespaces)
            label = entry[entry.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
        if label.isEmpty { label = value }
        guard !value.isEmpty else { return nil }
        if kind == .number, !scadIsNumberLiteral(value) { return nil }
        if !choices.contains(where: { scadValuesMatch($0.value, value, kind: kind) }) { choices.append(ScadChoice(value: value, label: label)) }
    }
    guard !choices.isEmpty, choices.count <= 200 else { return nil }
    return .choices(choices)
}

private func scadStartsKeyword(_ code: String, _ keyword: String) -> Bool {
    guard code.hasPrefix(keyword) else { return false }
    guard let next = code.dropFirst(keyword.count).first else { return true }
    return next.isWhitespace || next == "(" || next == "<"
}

/// The values OpenSCAD's Customizer would offer: top-level `name = literal;` lines before the first `module` or
/// `function` definition, outside any `/* [Hidden] */` section. A `//` comment on the line directly above is the
/// description; a trailing `//` comment can give choices, a range or a text length. Other lines are ignored.
func scadTemplateParameters(_ source: String) -> ScadTemplate {
    var template = ScadTemplate()
    var state = ScadScanState()
    var group: String?
    var hidden = false
    var definitionsStarted = false
    var pendingDescription: String?
    var positions: [String: Int] = [:]
    let lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        .split(separator: "\n", omittingEmptySubsequences: false)
    for (offset, rawLine) in lines.enumerated() {
        let startedAtTopLevel = state.depth == 0 && !state.inBlockComment && !state.inString
        let parts = scadScanLine(String(rawLine), state: &state)
        guard startedAtTopLevel else { pendingDescription = nil; continue }
        let code = parts.code.trimmingCharacters(in: .whitespaces)
        if code.isEmpty {
            if parts.lineComment == nil, parts.blockComments.count == 1 {
                let text = parts.blockComments[0].trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("["), text.hasSuffix("]"), text.count > 2 {
                    let name = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                    group = name
                    hidden = name.lowercased() == "hidden"
                }
                pendingDescription = nil
            } else if let comment = parts.lineComment, parts.blockComments.isEmpty {
                let text = comment.trimmingCharacters(in: .whitespaces)
                pendingDescription = text.isEmpty ? nil : String(text.prefix(300))
            } else {
                pendingDescription = nil
            }
            continue
        }
        if scadStartsKeyword(code, "include") || scadStartsKeyword(code, "use") { template.usesOtherFiles = true }
        if scadStartsKeyword(code, "module") || scadStartsKeyword(code, "function") { definitionsStarted = true }
        defer { pendingDescription = nil }
        guard !definitionsStarted, !hidden, let assignment = scadParseAssignment(code) else { continue }
        let kind: ScadValueKind
        let value: String
        switch assignment.value {
        case .string(let text): kind = .string; value = text
        case .number(let text): kind = .number; value = text
        case .boolean(let flag): kind = .boolean; value = flag ? "true" : "false"
        }
        let trailing = parts.lineComment.map { $0.trimmingCharacters(in: .whitespaces) }
        var parameter = ScadParameter(name: assignment.name, kind: kind, defaultValue: value, description: pendingDescription,
                                      group: group, line: offset + 1)
        switch trailing.flatMap({ scadConstraint($0, kind: kind) }) {
        case .choices(let choices)?:
            parameter.choices = choices
            if !choices.contains(where: { scadValuesMatch($0.value, value, kind: kind) }) {
                parameter.choices.insert(ScadChoice(value: value, label: value), at: 0)
            }
        case .range(let range)?: parameter.range = range
        case .maxLength(let length)?: parameter.maxLength = length
        case nil:
            if parameter.description == nil, let trailing, !trailing.isEmpty { parameter.description = String(trailing.prefix(300)) }
        }
        if let existing = positions[assignment.name] {
            // OpenSCAD uses the last assignment; keep the first one's place and description.
            if template.parameters[existing].kind == kind { template.parameters[existing].defaultValue = value }
            else { template.parameters.remove(at: existing); positions = Dictionary(uniqueKeysWithValues: template.parameters.enumerated().map { ($1.name, $0) }) }
            continue
        }
        positions[assignment.name] = template.parameters.count
        template.parameters.append(parameter)
    }
    template.endsCleanly = !state.inBlockComment && !state.inString && state.depth == 0
    return template
}

func scadValuesMatch(_ a: String, _ b: String, kind: ScadValueKind) -> Bool {
    if kind == .number, let x = Double(a.trimmingCharacters(in: .whitespaces)), let y = Double(b.trimmingCharacters(in: .whitespaces)) {
        return x == y
    }
    return a == b
}

// MARK: Values

/// Longest text Studio sends for one value when the template sets no limit.
let scadMaximumTextLength = 1_000

/// Why this value can't be used, or nil.
func scadValueProblem(_ value: String, for parameter: ScadParameter) -> String? {
    let label = parameter.description ?? parameter.name
    switch parameter.kind {
    case .string:
        if value.unicodeScalars.contains(where: { $0.value == 0 || (CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t") }) {
            return "\(label): text can’t contain control characters."
        }
        let limit = min(parameter.maxLength ?? scadMaximumTextLength, scadMaximumTextLength)
        if value.count > limit { return "\(label): use at most \(limit) characters." }
    case .number:
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard scadIsNumberLiteral(trimmed), let number = Double(trimmed) else {
            return "\(label): enter a number, such as 12 or 2.5."
        }
        if let range = parameter.range, !range.contains(number) {
            return "\(label): enter a number from \(range.lowerBound.formatted()) to \(range.upperBound.formatted())."
        }
    case .boolean:
        if value != "true", value != "false" { return "\(label): choose on or off." }
    }
    if !parameter.choices.isEmpty, !parameter.choices.contains(where: { scadValuesMatch($0.value, value, kind: parameter.kind) }) {
        return "\(label): choose one of the template’s options."
    }
    return nil
}

/// The value written as OpenSCAD source: an escaped string literal, the number as typed, or `true`/`false`.
/// Quotes and backslashes are escaped so a value can never end the string and add code.
func scadLiteral(_ value: String, kind: ScadValueKind) -> String {
    switch kind {
    case .number: return value.trimmingCharacters(in: .whitespaces)
    case .boolean: return value == "true" ? "true" : "false"
    case .string:
        var escaped = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    escaped += String(format: "\\x%02x", scalar.value == 0 ? 0x20 : scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return escaped + "\""
    }
}

struct ScadAssignment: Equatable {
    let name: String
    let literal: String
}

/// One assignment per parameter, in template order, using the typed value (or the default when none was typed).
func scadAssignments(_ parameters: [ScadParameter], values: [String: String]) -> [ScadAssignment] {
    parameters.map { ScadAssignment(name: $0.name, literal: scadLiteral(values[$0.name] ?? $0.defaultValue, kind: $0.kind)) }
}

/// Arguments for OpenSCAD's command line, passed straight to the process (no shell): `-o out.stl -D name=value … in.scad`.
/// Each `-D` is one argument, so spaces and quotes in values need only OpenSCAD's own string escaping.
func openSCADArguments(templatePath: String, outputPath: String, assignments: [ScadAssignment]) -> [String] {
    var arguments = ["-o", outputPath]
    for assignment in assignments { arguments += ["-D", "\(assignment.name)=\(assignment.literal)"] }
    arguments.append(templatePath)
    return arguments
}

/// The source sent to Slant: the template with the values appended as assignments. OpenSCAD uses a variable's last
/// assignment, which is also how its `-D` option works.
func scadSourceWithAssignments(_ source: String, assignments: [ScadAssignment]) -> String {
    guard !assignments.isEmpty else { return source }
    var result = source
    if !result.hasSuffix("\n") { result += "\n" }
    for assignment in assignments { result += "\(assignment.name) = \(assignment.literal);\n" }
    return result
}

// MARK: Naming

/// Library name for a generated model: “<template> – <text values>”, such as “Keychain – Emma”. Uses the text values
/// that differ from the template's defaults (else any changed value, else just the template name), sanitised like a
/// file name and kept within the library's name limit.
func personalisedModelName(templateName: String, parameters: [ScadParameter], values: [String: String]) -> String {
    func clean(_ text: String) -> String {
        let mapped = text.unicodeScalars.map { scalar -> String in
            if scalar == "/" || scalar == ":" { return "-" }
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) { return " " }
            return String(scalar)
        }.joined()
        return mapped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    var base = clean(templateName)
    if base.lowercased().hasSuffix(".scad") { base = String(base.dropLast(5)).trimmingCharacters(in: .whitespaces) }
    while base.hasPrefix(".") { base.removeFirst() }
    base = base.trimmingCharacters(in: .whitespaces)
    if base.isEmpty { base = "Template" }
    if base.count > 60 { base = String(base.prefix(60)).trimmingCharacters(in: .whitespaces) }
    let changed = parameters.filter { parameter in
        guard let value = values[parameter.name] else { return false }
        return !scadValuesMatch(value, parameter.defaultValue, kind: parameter.kind)
    }
    var pieces = changed.filter { $0.kind == .string }.map { clean(values[$0.name] ?? "") }.filter { !$0.isEmpty }
    if pieces.isEmpty {
        pieces = changed.filter { $0.kind != .string }.map { "\($0.name) \(clean(values[$0.name] ?? ""))" }
    }
    guard !pieces.isEmpty else { return base }
    var suffix = pieces.joined(separator: ", ")
    let room = maximumModelNameLength - base.count - 3
    if suffix.count > room { suffix = String(suffix.prefix(max(1, room - 1))).trimmingCharacters(in: .whitespaces) + "…" }
    return "\(base) – \(suffix)"
}

// MARK: Slant quota

/// Slant's OpenSCAD allowance as Studio sees it this session: 5 generations an hour, one at a time. Every request sent
/// counts, whatever its outcome, because Slant may count one that didn't reply. Studio can't see generations made with
/// the same key elsewhere (including the API Workbench), so Slant may refuse sooner. Memory only.
struct OpenSCADQuota: Equatable {
    static let generationsPerHour = 5
    static let window: TimeInterval = 3600
    private(set) var sentAt: [Date] = []
    private(set) var limitedUntil: Date?
    private(set) var inFlight = false

    private func counted(now: Date) -> [Date] {
        // A send dated after `now` (the clock moved back) still counts.
        sentAt.filter { now.timeIntervalSince($0) < Self.window }
    }

    func remaining(now: Date) -> Int { max(0, Self.generationsPerHour - counted(now: now).count) }

    /// When the next generation becomes available, or nil when one is available now.
    func nextAvailable(now: Date) -> Date? {
        var dates: [Date] = []
        if let limitedUntil, limitedUntil > now { dates.append(limitedUntil) }
        let recent = counted(now: now).sorted()
        if recent.count >= Self.generationsPerHour, let oldest = recent.first {
            dates.append(oldest.addingTimeInterval(Self.window))
        }
        return dates.max()
    }

    func blockedReason(now: Date) -> String? {
        if inFlight { return "A generation is already running on Slant." }
        guard let next = nextAvailable(now: now) else { return nil }
        let time = next.formatted(date: .omitted, time: .shortened)
        if let limitedUntil, limitedUntil > now {
            return "Slant’s OpenSCAD limit was reached. Try again after \(time)."
        }
        return "Studio has sent \(Self.generationsPerHour) generations to Slant in the last hour. The next is available after \(time)."
    }

    /// Records a send and marks it in flight; false (nothing recorded) when no generation is available.
    mutating func begin(now: Date) -> Bool {
        guard blockedReason(now: now) == nil else { return false }
        sentAt = counted(now: now) + [now]
        inFlight = true
        return true
    }

    mutating func finish() { inFlight = false }

    /// After a 429: blocked until `until`.
    mutating func noteRateLimited(until: Date) {
        limitedUntil = max(limitedUntil ?? until, until)
    }
}

/// After Slant refuses a generation with 429: a numeric Retry-After or a future `X-RateLimit-Reset` (each at most an
/// hour), else an hour, the length of Slant's OpenSCAD window.
func openSCADRateLimitedUntil(retryAfter: String?, rateLimitReset: String?, now: Date) -> Date {
    if let raw = retryAfter?.trimmingCharacters(in: .whitespaces), let seconds = TimeInterval(raw), seconds > 0, seconds.isFinite {
        return now.addingTimeInterval(min(seconds, OpenSCADQuota.window))
    }
    if let reset = rateLimitResetDate(rateLimitReset, now: now), reset > now {
        return min(reset, now.addingTimeInterval(OpenSCADQuota.window))
    }
    return now.addingTimeInterval(OpenSCADQuota.window)
}

// MARK: Engines

enum PersonalisationEngine: String, CaseIterable, Identifiable {
    case local, slant
    var id: String { rawValue }
    var title: String { self == .local ? "OpenSCAD on This Mac" : "Slant" }
}

/// Largest template Studio reads (OpenSCAD templates are small text files).
let scadMaximumTemplateBytes = 1_000_000

/// Where OpenSCAD.app is looked for: /Applications and ~/Applications, release then nightly builds.
func openSCADAppCandidates(homeDirectory: URL) -> [URL] {
    let folders = [URL(fileURLWithPath: "/Applications"), homeDirectory.appendingPathComponent("Applications")]
    return folders.flatMap { folder in
        ["OpenSCAD.app", "OpenSCAD-nightly.app", "OpenSCAD Nightly.app"].map { folder.appendingPathComponent($0) }
    }
}

/// The first installed OpenSCAD command-line executable, or nil.
func installedOpenSCADExecutable(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
    for app in openSCADAppCandidates(homeDirectory: homeDirectory) {
        let executable = Bundle(url: app)?.executableURL ?? app.appendingPathComponent("Contents/MacOS/OpenSCAD")
        if FileManager.default.isExecutableFile(atPath: executable.path) { return executable }
    }
    return nil
}

func personalisationDefaultEngine(localAvailable: Bool) -> PersonalisationEngine { localAvailable ? .local : .slant }

/// Why the chosen engine can't generate now, or nil.
func personalisationEngineBlockedReason(_ engine: PersonalisationEngine, localAvailable: Bool, hasKey: Bool,
                                        template: ScadTemplate, sourceBytes: Int, quota: OpenSCADQuota, now: Date) -> String? {
    switch engine {
    case .local:
        return localAvailable ? nil : "OpenSCAD isn’t installed in Applications. Install it from openscad.org, or generate with Slant."
    case .slant:
        if !hasKey { return "Connect your Slant account in Settings to generate with Slant." }
        if template.usesOtherFiles {
            return "This template uses other files (include or use), which Slant can’t read. Generate it with OpenSCAD on this Mac."
        }
        if !template.endsCleanly {
            return "This template ends inside a comment, text or bracket, so Studio can’t add your values to it for Slant."
        }
        if sourceBytes > scadMaximumTemplateBytes { return "This template is too large to send to Slant." }
        return quota.blockedReason(now: now)
    }
}

/// The most useful line of OpenSCAD's log for an error message: its first `ERROR:` line, else the last line.
func openSCADErrorSummary(_ log: String) -> String? {
    let lines = log.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard let line = lines.first(where: { $0.uppercased().hasPrefix("ERROR") }) ?? lines.last else { return nil }
    return line.count > 300 ? String(line.prefix(300)) + "…" : line
}

/// Checks generated bytes as an STL, like any import, and returns the same geometry as a binary STL.
func personalisedSTLData(_ data: Data) throws -> Data {
    guard !data.isEmpty else { throw StudioError("The generated model is empty. Check the template’s values.") }
    let mesh: STLMesh
    do { mesh = try STLMesh.parse(data) } catch {
        throw StudioError("The generated file isn’t a usable STL. \(error.localizedDescription)")
    }
    return try mesh.stlCopyData()
}

// MARK: Local OpenSCAD

enum OpenSCADRunError: LocalizedError, Equatable {
    case timedOut(TimeInterval), outputTooLarge, failed(status: Int32, summary: String?), noOutput(String?), cancelled

    var errorDescription: String? {
        switch self {
        case .timedOut(let seconds):
            return "OpenSCAD didn’t finish within \(Int(seconds / 60)) minutes, so Studio stopped it."
        case .outputTooLarge:
            return "OpenSCAD’s output grew past Studio’s 128 MB limit, so Studio stopped it."
        case .failed(let status, let summary):
            return "OpenSCAD couldn’t generate the model (exit code \(status))." + (summary.map { " \($0)" } ?? "")
        case .noOutput(let summary):
            return "OpenSCAD finished without writing a model." + (summary.map { " \($0)" } ?? "")
        case .cancelled:
            return "Generation stopped."
        }
    }
}

private final class OpenSCADProcessBox: @unchecked Sendable {
    let process = Process()
    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// Runs OpenSCAD (no shell) and returns the bytes it writes to `-o`. It is stopped when the task is cancelled, after
/// `timeout`, or once its output or log grows past their limits. The log goes to a file so a full pipe can't stall it.
func runOpenSCADProcess(executable: URL, templateURL: URL, assignments: [ScadAssignment], timeout: TimeInterval = 300,
                        maxOutputBytes: Int = STLMesh.maximumBytes, maxLogBytes: Int = 4_000_000) async throws -> Data {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SlantStudio-OpenSCAD-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let output = folder.appendingPathComponent("model.stl")
    let logURL = folder.appendingPathComponent("log.txt")
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    let log = try FileHandle(forWritingTo: logURL)
    defer { try? log.close() }
    let box = OpenSCADProcessBox()
    box.process.executableURL = executable
    box.process.arguments = openSCADArguments(templatePath: templateURL.path, outputPath: output.path, assignments: assignments)
    box.process.currentDirectoryURL = templateURL.deletingLastPathComponent()
    box.process.standardInput = FileHandle.nullDevice
    box.process.standardOutput = log
    box.process.standardError = log
    // Not URL.resourceValues, which caches the first size it reads.
    func fileSize(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0 }
    func logSummary() -> String? {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 64_000)) ?? Data()
        return openSCADErrorSummary(String(decoding: data, as: UTF8.self))
    }
    try Task.checkCancellation()
    try box.process.run()
    let started = Date()
    try await withTaskCancellationHandler {
        while box.process.isRunning {
            if Task.isCancelled { box.stop(); throw OpenSCADRunError.cancelled }
            if Date().timeIntervalSince(started) > timeout { box.stop(); throw OpenSCADRunError.timedOut(timeout) }
            if fileSize(output) > maxOutputBytes || fileSize(logURL) > maxLogBytes { box.stop(); throw OpenSCADRunError.outputTooLarge }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    } onCancel: {
        box.stop()
    }
    if Task.isCancelled { throw OpenSCADRunError.cancelled }
    box.process.waitUntilExit()
    guard box.process.terminationReason == .exit, box.process.terminationStatus == 0 else {
        throw OpenSCADRunError.failed(status: box.process.terminationStatus, summary: logSummary())
    }
    guard FileManager.default.fileExists(atPath: output.path) else { throw OpenSCADRunError.noOutput(logSummary()) }
    guard fileSize(output) <= maxOutputBytes else { throw OpenSCADRunError.outputTooLarge }
    return try Data(contentsOf: output)
}

// MARK: Import Orders personalisation

/// Headers of a dedicated personalisation column (Etsy puts personalisation in "Variations"; some exports and Studio's
/// template may carry it separately). Compared with `orderImportHeaderKey`, so case and spacing don't matter.
let orderImportPersonalisationColumns = ["Personalization", "Personalisation", "Personalization Details", "Personalisation Details"]

/// Etsy writes this when a listing offers personalisation but the buyer added none.
private func orderImportPersonalisationIsEmpty(_ text: String) -> Bool {
    let lowered = text.lowercased()
    return lowered.isEmpty || lowered.hasPrefix("not requested")
}

/// The buyer's personalisation for one item: a dedicated column's text, else the value after `Personalization:` (or
/// `Personalisation:`) in Etsy's "Variations" text, such as `Colour:Red,Personalization:Emma`. The value runs to the
/// next `,Label:` option or the end. Etsy's "Not requested on this item." counts as none. Display only.
func orderImportPersonalisation(options: String, column: String) -> String {
    let dedicated = column.trimmingCharacters(in: .whitespacesAndNewlines)
    if !dedicated.isEmpty { return orderImportPersonalisationIsEmpty(dedicated) ? "" : dedicated }
    guard let label = options.range(of: #"(?:^|,)\s*personali[sz]ation\s*:"#, options: [.regularExpression, .caseInsensitive]) else {
        return ""
    }
    var value = options[label.upperBound...]
    if let next = value.range(of: #",\s*[A-Za-z][A-Za-z0-9 ]{0,29}:"#, options: .regularExpression) {
        value = value[..<next.lowerBound]
    }
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return orderImportPersonalisationIsEmpty(text) ? "" : text
}

/// Shown above the Import Orders list when any order carries personalisation.
let orderImportPersonalisationNote = "Buyers’ personalisation is shown so you can make each model with Personalise from Template: copy it, then paste it there. It stays in this window, isn’t saved and isn’t sent with the drafts, which use each saved product’s model unchanged."

/// Every personalisation in the file as lines of “order ID · item: text”, for Copy All (the list is gone once the
/// sheet closes, and Personalise from Template can't open over it). No names or addresses.
func orderImportPersonalisationList(_ orders: [OrderImportOrder]) -> String {
    orders.flatMap { order in
        order.items.filter { !$0.personalisation.isEmpty }.map { item in
            let text = item.personalisation.split(whereSeparator: \.isNewline).joined(separator: " / ")
            return item.itemName.isEmpty ? "\(order.sourceOrderID): \(text)" : "\(order.sourceOrderID) · \(item.itemName): \(text)"
        }
    }.joined(separator: "\n")
}

/// True when the options text holds more than the personalisation, so the preview shows it for context.
func orderImportPersonalisationShowsOptions(_ item: OrderImportItem) -> Bool {
    let options = item.options.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !options.isEmpty, !item.personalisation.isEmpty else { return false }
    let bare = options.replacingOccurrences(of: #"^\s*personali[sz]ation\s*:"#, with: "", options: [.regularExpression, .caseInsensitive])
    return bare.trimmingCharacters(in: .whitespacesAndNewlines) != item.personalisation
}

// MARK: Loading templates

/// A chosen template, held in memory while the Personalise sheet is open.
struct PersonalisationTemplateFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let source: String
    let template: ScadTemplate
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// Reads a .scad file (UTF-8, at most 1 MB) and finds its values.
func loadPersonalisationTemplate(_ url: URL) throws -> PersonalisationTemplateFile {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    guard size <= scadMaximumTemplateBytes else { throw StudioError("This template is larger than 1 MB, so Studio can’t read it.") }
    let data = try Data(contentsOf: url)
    guard data.count <= scadMaximumTemplateBytes else { throw StudioError("This template is larger than 1 MB, so Studio can’t read it.") }
    guard var source = String(data: data, encoding: .utf8) else {
        throw StudioError("Studio couldn’t read this template. Save it as UTF-8 text and try again.")
    }
    if source.hasPrefix("\u{FEFF}") { source.removeFirst() }
    return PersonalisationTemplateFile(url: url, source: source, template: scadTemplateParameters(source))
}

/// Holds Slant's OpenSCAD quota for the app session, across openings of the sheet.
@MainActor final class PersonalisationSession: ObservableObject {
    static let shared = PersonalisationSession()
    @Published var quota = OpenSCADQuota()
}

extension StudioStore {
    /// File › Personalise from Template… and the Models Import menu: choose a .scad file, then show the sheet. Does
    /// nothing while a sheet, alert or dialog is open. Nothing is sent until Generate with Slant is pressed.
    func personaliseFromTemplateFromMenu() {
        guard !menuCommandsBlockedByModalUI else { return }
        chooseAndOpenPersonalisationTemplate()
    }

    func chooseAndOpenPersonalisationTemplate() {
        guard let url = choosePersonalisationTemplateURL() else { return }
        do { personalisationTemplate = try loadPersonalisationTemplate(url) }
        catch { showError(error.localizedDescription) }
    }

    func choosePersonalisationTemplateURL() -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Choose an OpenSCAD template (.scad) with values to fill in, such as a name."
        panel.allowedContentTypes = [UTType(filenameExtension: "scad") ?? .plainText]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// One `POST /files/openScad`, never retried. It counts against the session quota as it is sent, whatever the
    /// outcome; a 429 blocks further generations until Slant's reset. Uses `run`, so it waits for (and blocks) other
    /// requests, and Activity records only the title and outcome, never the template or values.
    func generateOpenSCADOnSlant(source: String) async throws -> Data {
        let session = PersonalisationSession.shared
        if let reason = session.quota.blockedReason(now: Date()) { throw StudioError(reason) }
        guard !busy else { throw StudioError("Another request is running. Try again when it finishes.") }
        var bytes: Data?
        var failure: Error?
        let ran = await run("Generate from template", handlesError: { failure = $0; return true }) {
            guard session.quota.begin(now: Date()) else {
                throw StudioError(session.quota.blockedReason(now: Date()) ?? "Slant’s OpenSCAD limit was reached.")
            }
            defer { session.quota.finish() }
            let response = try await client.request("POST", path: "/files/openScad", body: ["scadCode": source])
            bytes = response.data
        }
        guard ran else { throw StudioError("Another request is running. Try again when it finishes.") }
        if let failure {
            if case APIError.http(429, _, let retryAfter, let reset) = failure {
                session.quota.noteRateLimited(until: openSCADRateLimitedUntil(retryAfter: retryAfter, rateLimitReset: reset, now: Date()))
            }
            throw failure
        }
        guard let bytes else { throw StudioError("Slant didn’t return a model.") }
        return bytes
    }

    /// Checks STL bytes and saves them as a new library model named `name`, through the normal import path (which
    /// selects it on Models). Never uploads. Returns why it wasn't saved, or nil.
    func savePersonalisedModel(_ stl: Data, name: String) async -> String? {
        let fileName = exportFileName(modelName: name, fileExtension: "stl")
        let result = await Task.detached(priority: .userInitiated) {
            Result { () -> URL in
                let data = try personalisedSTLData(stl)
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent(fileName)
                do { try data.write(to: url, options: .atomic) }
                catch { try? FileManager.default.removeItem(at: folder); throw error }
                return url
            }
        }.value
        switch result {
        case .success(let url):
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            // importModel shows its own alert if copying into the library fails.
            guard importModel(url) else { return "The model couldn’t be added to your library." }
            // No name in Activity: a generated model's name can include a customer's name.
            activities.insert(Activity(title: "Personalise from template", detail: "Saved a new model", success: true), at: 0)
            return nil
        case .failure(let error):
            return error.localizedDescription
        }
    }
}
