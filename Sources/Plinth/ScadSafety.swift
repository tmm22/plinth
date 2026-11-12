import Foundation

// MARK: - Checking OpenSCAD code Claude wrote before running it
//
// Design an Accessory from a Photo runs OpenSCAD code that Claude writes on the seller's Mac. OpenSCAD can't run
// programs, but it can read files. In OpenSCAD 2021.01 (the stable release Plinth looks for first) a script reaches a
// file only through `include <…>` and `use <…>`; the modules `import`, `import_stl`, `import_off`, `import_dxf` and
// `surface`; the old `dxf_dim` and `dxf_cross` functions and `dxf_linear_extrude` / `dxf_rotate_extrude` modules; and
// the `file` parameter of `linear_extrude` and `rotate_extrude`, which is also their FIRST UNNAMED argument wherever it
// sits in the list (`linear_extrude(height = 2, p)` reads `p` as a file). OpenSCAD 2026.11 drops the `import_…`
// modules and the extrude modules' `file`; the ways it keeps are all on the list. Plinth refuses code that uses any of
// these words, a `file =` argument or variable, or an unnamed argument to either extrude module (a plain number as
// linear_extrude's legacy height excepted), before OpenSCAD ever sees it. Because OpenSCAD's lexers treat a no-break space (and, in newer builds, a
// byte-order mark) as whitespace, any character other than plain ASCII outside strings and comments is refused too, so
// `file<no-break space>= p` can't look like something else here.
//
// The guarantee rests on refusing every file-reading word and argument shape: a string can be built at runtime
// (`str(chr(47), "etc")`), so the check for strings that look like a file path is only a second layer. The code is
// written to an empty temporary folder and run without a shell, with a time limit, a memory cap and bounded output
// (`runOpenSCADProcess`), so what is left is ordinary geometry.

/// Largest OpenSCAD source Studio runs from Claude.
let scadSafetyMaximumBytes = 64 * 1024

/// Words that make OpenSCAD read another file. Compared as whole identifiers outside comments and strings.
let scadSafetyFileReadingWords = ["include", "use", "import", "import_stl", "import_off", "import_dxf", "surface",
                                   "dxf_linear_extrude", "dxf_rotate_extrude", "dxf_dim", "dxf_cross"]

/// Modules whose first unnamed argument OpenSCAD 2021.01 binds to their `file` parameter and reads as a file.
let scadSafetyExtrudeModules = ["linear_extrude", "rotate_extrude"]

/// File extensions a string literal mustn't end with: things OpenSCAD (or a later version of it) could read.
let scadSafetyFileExtensions = ["stl", "scad", "dxf", "svg", "png", "dat", "off", "obj", "3mf", "amf", "csg", "json", "txt", "csv", "ttf", "otf"]

/// Why Studio won't run this code, or nil when it may. The message is written for Claude (it goes back as the tool
/// result) and also shown to the seller.
func scadSafetyProblem(_ code: String) -> String? {
    let bytes = code.utf8.count
    if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "The code is empty." }
    if bytes > scadSafetyMaximumBytes {
        return "The code is \(bytes.formatted()) bytes; Plinth runs at most \(scadSafetyMaximumBytes.formatted()) bytes. Make it shorter."
    }
    if code.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t" }) {
        return "The code contains control characters. Use plain text only."
    }
    // OpenSCAD's lexer ends a `//` comment only at a line feed, so a carriage return on its own would let text that
    // OpenSCAD runs look like part of a comment here (or the reverse, in a build that ends comments at either). Windows
    // line endings, a carriage return straight before a line feed, read the same both ways and stay allowed.
    if scadSafetyHasLoneCarriageReturn(code) {
        return "The code contains a carriage return that isn’t part of a line break. Use plain line breaks only."
    }
    let scan = scadSafetyScan(code)
    if let problem = scan.problem { return problem }
    for word in scadSafetyFileReadingWords where scan.identifiers.contains(word) {
        switch word {
        case "include", "use":
            return "Plinth doesn’t run code that uses `\(word)`: everything must be in this one file. Write any library modules you need inline."
        case _ where word.hasPrefix("dxf_"):
            return "Plinth doesn’t run code that uses `\(word)`, because it reads DXF files. Build the shape from OpenSCAD primitives instead."
        default:
            return "Plinth doesn’t run code that calls `\(word)()`, because it reads files. Build the shape from OpenSCAD primitives instead."
        }
    }
    if scan.usesFileArgument {
        return "Plinth doesn’t run code with a `file =` argument or variable, because OpenSCAD reads files through it. Build the shape from OpenSCAD primitives, and give variables other names."
    }
    if scan.unnamedExtrudeArgument != nil {
        return "Plinth doesn’t run `linear_extrude` or `rotate_extrude` with an unnamed argument (other than a plain number as linear_extrude’s height), because OpenSCAD 2021.01 reads the first unnamed argument as a file. Name each argument: height = …, angle = …, center = …."
    }
    if let path = scan.strings.first(where: scadSafetyLooksLikePath) {
        let shown = path.count > 40 ? String(path.prefix(40)) + "…" : path
        return "Plinth doesn’t run code with text that looks like a file path (\"\(shown)\"). Remove it."
    }
    return nil
}

/// True when the code has a carriage return that isn't straight before a line feed.
func scadSafetyHasLoneCarriageReturn(_ code: String) -> Bool {
    let scalars = Array(code.unicodeScalars)
    for (index, scalar) in scalars.enumerated() where scalar == "\r" {
        if index + 1 >= scalars.count || scalars[index + 1] != "\n" { return true }
    }
    return false
}

/// True for text that names a file or folder: an absolute, home or relative path, a Windows drive or backslash path,
/// a `/` followed anywhere by a system or home folder, a `~` or a `..` segment, or a name ending in a model, image,
/// data or font file extension. OpenSCAD 2021.01 drops a line break typed straight into a string (`"⏎/etc"` reads as
/// "/etc"), so the text is also checked with its line breaks removed.
func scadSafetyLooksLikePath(_ text: String) -> Bool {
    if scadSafetyTextLooksLikePath(text) { return true }
    let joined = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != "\n" && $0 != "\r" }))
    return joined != text && scadSafetyTextLooksLikePath(joined)
}

private func scadSafetyTextLooksLikePath(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix("./") || trimmed.hasPrefix("../") { return true }
    if trimmed.contains("\\") || trimmed.contains("../") || trimmed.contains("/./") { return true }
    let segments = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    if segments.contains("..") { return true }
    // A system folder or `~` matters only in a path that leaves the empty temporary folder OpenSCAD runs in (absolute,
    // home-relative or climbing with `..`, all refused above), so label text such as "Work/Home" stays allowed.
    if trimmed.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil { return true }
    if trimmed.lowercased().hasPrefix("file:") { return true }
    if let dot = trimmed.lastIndex(of: ".") {
        let ext = trimmed[trimmed.index(after: dot)...].lowercased()
        if scadSafetyFileExtensions.contains(ext), dot != trimmed.startIndex { return true }
    }
    return false
}

struct ScadSafetyScan: Equatable {
    /// Identifiers outside comments and strings, in order of first appearance.
    var identifiers: [String] = []
    /// String literals' contents (escapes resolved), in order.
    var strings: [String] = []
    /// `file` is assigned or passed as a named argument (`file = …`, not `file == …`), even with comments in between.
    var usesFileArgument = false
    /// The extrude module (`scadSafetyExtrudeModules`) called with an argument that isn't `name = …`, other than a plain
    /// number as linear_extrude's first argument: OpenSCAD 2021.01 reads the first unnamed one as a file.
    var unnamedExtrudeArgument: String?
    /// Set when the code ends inside a comment or a string, or has a character other than plain ASCII outside them.
    var problem: String?
}

/// One token of OpenSCAD code outside comments, as `scadSafetyScan` reads it for the argument rules.
enum ScadSafetyToken: Equatable {
    case identifier(String)
    /// A plain number: `[0-9]*\.?[0-9]+([eE][+-]?[0-9]+)?`. Digits followed by letters (`12abc`, an identifier in
    /// OpenSCAD) read as a number and then an identifier here, which only makes the rules stricter.
    case number
    case string
    /// One punctuation character, or one of OpenSCAD's two-character operators (`==`, `!=`, `<=`, `>=`, `&&`, `||`).
    case symbol(String)
}

/// The character an OpenSCAD `\x`, `\u` or `\U` escape stands for and how many hex digits it used, or nil when the
/// escape isn't well formed (`\x` takes two hex digits up to 7F, `\u` four and `\U` six).
func scadSafetyHexEscape(_ kind: Unicode.Scalar, digits: ArraySlice<Unicode.Scalar>) -> (scalar: Unicode.Scalar, length: Int)? {
    let length: Int
    switch kind {
    case "x": length = 2
    case "u": length = 4
    case "U": length = 6
    default: return nil
    }
    guard digits.count >= length else { return nil }
    var value: UInt32 = 0
    for digit in digits.prefix(length) {
        guard digit.isASCII, let nibble = UInt32(String(digit), radix: 16) else { return nil }
        value = value * 16 + nibble
    }
    if kind == "x", value > 0x7F { return nil }
    guard let scalar = Unicode.Scalar(value) else { return nil }
    return (scalar, length)
}

/// Walks the code once, skipping `//` and `/* */` comments and reading string literals, so a word inside a comment or
/// a `text("…")` label doesn't count, and a keyword hidden behind a comment can't slip through either.
func scadSafetyScan(_ code: String) -> ScadSafetyScan {
    var scan = ScadSafetyScan()
    var seen = Set<String>()
    /// Every token outside comments, in order, for the argument rules once the walk is done.
    var tokens: [ScadSafetyToken] = []
    let chars = Array(code.unicodeScalars)
    var index = 0
    func isDigit(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }
    func isIdentifierStart(_ c: Unicode.Scalar) -> Bool { c == "_" || c == "$" || (c.isASCII && CharacterSet.letters.contains(c)) }
    func isIdentifierPart(_ c: Unicode.Scalar) -> Bool { isIdentifierStart(c) || isDigit(c) }
    while index < chars.count {
        let c = chars[index]
        let next: Unicode.Scalar? = index + 1 < chars.count ? chars[index + 1] : nil
        if c == " " || c == "\t" || c == "\n" || c == "\r" { index += 1; continue }
        if c == "/", next == "/" {
            while index < chars.count, chars[index] != "\n", chars[index] != "\r" { index += 1 }
            continue
        }
        if c == "/", next == "*" {
            index += 2
            var closed = false
            while index < chars.count {
                if chars[index] == "*", index + 1 < chars.count, chars[index + 1] == "/" { index += 2; closed = true; break }
                index += 1
            }
            if !closed { scan.problem = "The code ends inside a /* comment. Close it with */."; return scan }
            continue
        }
        if c == "\"" {
            index += 1
            var text = String.UnicodeScalarView()
            var closed = false
            while index < chars.count {
                let s = chars[index]
                if s == "\\", index + 1 < chars.count {
                    let escaped = chars[index + 1]
                    switch escaped {
                    case "n": text.append("\n")
                    case "t": text.append("\t")
                    case "r": text.append("\r")
                    case "\"": text.append("\"")
                    case "\\": text.append("\\")
                    case "x", "u", "U":
                        // `\x2F` and its four-digit `\u` and six-digit `\U` forms stand for one character ("/"), so they are decoded
                        // before the path check. One that isn't well formed is kept with its backslash, which the
                        // path check refuses.
                        if let decoded = scadSafetyHexEscape(escaped, digits: chars[(index + 2)...]) {
                            text.append(decoded.scalar)
                            index += 2 + decoded.length
                        } else {
                            text.append("\\")
                            text.append(escaped)
                            index += 2
                        }
                        continue
                    // Any other escape is the character itself.
                    default: text.append(escaped)
                    }
                    index += 2
                    continue
                }
                if s == "\"" { index += 1; closed = true; break }
                text.append(s)
                index += 1
            }
            if !closed { scan.problem = "The code ends inside a text string. Close it with \"."; return scan }
            scan.strings.append(String(text))
            tokens.append(.string)
            continue
        }
        // OpenSCAD reads a no-break space (and, in newer builds, a byte-order mark) between tokens as whitespace, and
        // newer builds allow other letters in names, so outside strings and comments only plain ASCII is allowed.
        if !c.isASCII {
            scan.problem = "The code has a character that isn’t plain ASCII outside text strings and comments (such as a no-break space). Use plain ASCII there."
            return scan
        }
        if isIdentifierStart(c) {
            var word = String.UnicodeScalarView()
            while index < chars.count, isIdentifierPart(chars[index]) { word.append(chars[index]); index += 1 }
            let name = String(word)
            if seen.insert(name).inserted { scan.identifiers.append(name) }
            tokens.append(.identifier(name))
            continue
        }
        if isDigit(c) || (c == "." && next.map(isDigit) == true) {
            while index < chars.count, isDigit(chars[index]) { index += 1 }
            if index + 1 < chars.count, chars[index] == ".", isDigit(chars[index + 1]) {
                index += 1
                while index < chars.count, isDigit(chars[index]) { index += 1 }
            }
            if index < chars.count, chars[index] == "e" || chars[index] == "E" {
                var digits = index + 1
                if digits < chars.count, chars[digits] == "+" || chars[digits] == "-" { digits += 1 }
                if digits < chars.count, isDigit(chars[digits]) {
                    index = digits
                    while index < chars.count, isDigit(chars[index]) { index += 1 }
                }
            }
            tokens.append(.number)
            continue
        }
        if let next, ["==", "!=", "<=", ">=", "&&", "||"].contains(String(c) + String(next)) {
            tokens.append(.symbol(String(c) + String(next)))
            index += 2
            continue
        }
        // `<path>` after include/use is caught by the word itself; anything else is ordinary code.
        tokens.append(.symbol(String(c)))
        index += 1
    }
    scan.usesFileArgument = scadSafetyAssignsFile(tokens)
    scan.unnamedExtrudeArgument = scadSafetyUnnamedExtrudeArgument(tokens)
    return scan
}

/// The identifier just before `tokens[index]`, passing over numbers: OpenSCAD 2021.01 silently drops a number it can't
/// convert, so `linear_extrude 1e999 (p)` may be a call there.
private func scadSafetyIdentifier(before index: Int, in tokens: [ScadSafetyToken]) -> String? {
    var position = index - 1
    while position >= 0, tokens[position] == .number { position -= 1 }
    guard position >= 0, case .identifier(let name) = tokens[position] else { return nil }
    return name
}

/// True when `file` is assigned or passed by name (`file = …`, not `file == …`), passing over numbers between the two
/// for the same reason as `scadSafetyIdentifier(before:in:)`.
func scadSafetyAssignsFile(_ tokens: [ScadSafetyToken]) -> Bool {
    for (index, token) in tokens.enumerated() where token == .symbol("=") {
        if scadSafetyIdentifier(before: index, in: tokens) == "file" { return true }
    }
    return false
}

/// The extrude module called with an argument OpenSCAD 2021.01 could read as a file, or nil. In every call of a
/// `scadSafetyExtrudeModules` module, each argument must start with a name followed by `=` (not `==`); the one
/// exception is a plain number as linear_extrude's first argument, followed by `,` or `)`, which is its legacy height
/// and never read as a file. `()` and a trailing comma pass. Brackets are tracked across the whole token list
/// (comments and whitespace are already gone), so a comma inside `max(1, h)` or `[1, 2]` doesn't start an argument.
/// OpenSCAD parses the whole file before it runs any of it, so code with unbalanced brackets never runs.
func scadSafetyUnnamedExtrudeArgument(_ tokens: [ScadSafetyToken]) -> String? {
    struct Frame {
        /// The extrude module this `(` called, or nil for any other bracket.
        var module: String?
        var argumentIndex = 0
        var atArgumentStart = true
    }
    var frames: [Frame] = []
    for (index, token) in tokens.enumerated() {
        let following: ScadSafetyToken? = index + 1 < tokens.count ? tokens[index + 1] : nil
        if let frame = frames.last, let module = frame.module, frame.atArgumentStart {
            switch token {
            case .symbol(")"):
                break // No argument here: `()`, or a trailing comma.
            case .identifier where following == .symbol("="):
                frames[frames.count - 1].atArgumentStart = false
            case .number where module == "linear_extrude" && frame.argumentIndex == 0
                && (following == .symbol(",") || following == .symbol(")")):
                frames[frames.count - 1].atArgumentStart = false
            default:
                return module
            }
        }
        switch token {
        case .symbol("("):
            let name = scadSafetyIdentifier(before: index, in: tokens)
            frames.append(Frame(module: name.flatMap { scadSafetyExtrudeModules.contains($0) ? $0 : nil }))
        case .symbol("["), .symbol("{"):
            frames.append(Frame(module: nil))
        case .symbol(")"), .symbol("]"), .symbol("}"):
            if !frames.isEmpty { frames.removeLast() }
        case .symbol(","):
            if let frame = frames.last, frame.module != nil {
                frames[frames.count - 1].argumentIndex += 1
                frames[frames.count - 1].atArgumentStart = true
            }
        default:
            break
        }
    }
    return nil
}
