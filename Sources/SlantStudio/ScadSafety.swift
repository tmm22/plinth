import Foundation

// MARK: - Checking OpenSCAD code Claude wrote before running it
//
// Design an Accessory from a Photo runs OpenSCAD code that Claude writes on the seller's Mac. OpenSCAD can't run
// programs, but it can read files: `include <…>`, `use <…>`, `import("…")` and `surface("…")`. Studio refuses code
// that uses any of them, or carries something that looks like a file path, before OpenSCAD ever sees it. The code is
// written to an empty temporary folder and run without a shell, with a time limit and bounded output
// (`runOpenSCADProcess`), so what is left is ordinary geometry.

/// Largest OpenSCAD source Studio runs from Claude.
let scadSafetyMaximumBytes = 64 * 1024

/// Words that make OpenSCAD read another file. Compared as whole identifiers outside comments and strings.
let scadSafetyFileReadingWords = ["include", "use", "import", "surface"]

/// File extensions a string literal mustn't end with: things OpenSCAD (or a later version of it) could read.
let scadSafetyFileExtensions = ["stl", "scad", "dxf", "svg", "png", "dat", "off", "obj", "3mf", "amf", "csg", "json", "txt", "csv", "ttf", "otf"]

/// Why Studio won't run this code, or nil when it may. The message is written for Claude (it goes back as the tool
/// result) and also shown to the seller.
func scadSafetyProblem(_ code: String) -> String? {
    let bytes = code.utf8.count
    if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "The code is empty." }
    if bytes > scadSafetyMaximumBytes {
        return "The code is \(bytes.formatted()) bytes; Studio runs at most \(scadSafetyMaximumBytes.formatted()) bytes. Make it shorter."
    }
    if code.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t" }) {
        return "The code contains control characters. Use plain text only."
    }
    let scan = scadSafetyScan(code)
    if let problem = scan.problem { return problem }
    for word in scadSafetyFileReadingWords where scan.identifiers.contains(word) {
        switch word {
        case "include", "use":
            return "Studio doesn’t run code that uses `\(word)`: everything must be in this one file. Write any library modules you need inline."
        default:
            return "Studio doesn’t run code that calls `\(word)()`, because it reads files. Build the shape from OpenSCAD primitives instead."
        }
    }
    if let path = scan.strings.first(where: scadSafetyLooksLikePath) {
        let shown = path.count > 40 ? String(path.prefix(40)) + "…" : path
        return "Studio doesn’t run code with text that looks like a file path (\"\(shown)\"). Remove it."
    }
    return nil
}

/// True for text that names a file or folder: an absolute, home or relative path, a Windows drive or backslash path,
/// or a name ending in a model, image, data or font file extension.
func scadSafetyLooksLikePath(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix("./") || trimmed.hasPrefix("../") { return true }
    if trimmed.contains("\\") || trimmed.contains("../") || trimmed.contains("/./") { return true }
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
    /// Set when the code ends inside a comment or a string.
    var problem: String?
}

/// Walks the code once, skipping `//` and `/* */` comments and reading string literals, so a word inside a comment or
/// a `text("…")` label doesn't count, and a keyword hidden behind a comment can't slip through either.
func scadSafetyScan(_ code: String) -> ScadSafetyScan {
    var scan = ScadSafetyScan()
    var seen = Set<String>()
    let chars = Array(code.unicodeScalars)
    var index = 0
    func isIdentifierStart(_ c: Unicode.Scalar) -> Bool { c == "_" || c == "$" || (c.isASCII && CharacterSet.letters.contains(c)) }
    func isIdentifierPart(_ c: Unicode.Scalar) -> Bool { isIdentifierStart(c) || (c.isASCII && CharacterSet.decimalDigits.contains(c)) }
    while index < chars.count {
        let c = chars[index]
        let next: Unicode.Scalar? = index + 1 < chars.count ? chars[index + 1] : nil
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
                    // `\x41`, `°` and `\U01F600` stand for one character; any other escape is the character itself.
                    case "x", "u", "U": text.append("?")
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
            continue
        }
        if isIdentifierStart(c) {
            var word = String.UnicodeScalarView()
            while index < chars.count, isIdentifierPart(chars[index]) { word.append(chars[index]); index += 1 }
            let name = String(word)
            if seen.insert(name).inserted { scan.identifiers.append(name) }
            continue
        }
        // `<path>` after include/use is caught by the word itself; anything else is ordinary code.
        index += 1
    }
    return scan
}
