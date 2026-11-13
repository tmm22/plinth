import XCTest

/// Source checks for wiring that tests can't drive because it needs a `StudioStore` (the app's live environments and the
/// calls that hand them to the money and upload flows). They compare code, not text: `//` comments are removed and every
/// run of whitespace becomes one space, in the source and in the snippet alike, so reformatting never breaks a check,
/// while a pinned call that survives only in a comment does. Each check says what it protects. If you only reformatted
/// or renamed something, update the snippet to the equivalent code; never delete a check without a replacement.
enum SourceCheck {
    struct Problem: Error, CustomStringConvertible {
        let description: String
    }

    /// A file under Sources/Plinth, as code (`code(_:)`).
    static func file(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Plinth").appendingPathComponent(name)
        return code(try String(contentsOf: url, encoding: .utf8))
    }

    /// Swift source without `//` comments (a `//` inside a one-line string literal is kept), with every run of whitespace
    /// turned into one space.
    static func code(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { withoutLineComment($0) }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func withoutLineComment(_ line: Substring) -> Substring {
        var inString = false
        var escaped = false
        var previousSlash: String.Index?
        for index in line.indices {
            let character = line[index]
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            if character == "\"" {
                inString = true
                previousSlash = nil
            } else if character == "/" {
                if let slash = previousSlash { return line[..<slash] }
                previousSlash = index
            } else {
                previousSlash = nil
            }
        }
        return line
    }

    /// The code of the declaration starting at `signature`, through the brace that closes its body: the first `{` outside
    /// the parameter list (so a default closure argument isn't taken for the body), with braces inside string literals
    /// not counted. Throws, failing the test, when the signature is missing or the braces don't balance.
    static func body(of signature: String, in code: String) throws -> String {
        let signature = Self.code(signature)
        guard let start = code.range(of: signature) else {
            throw Problem(description: "Source check: no “\(signature)” in the source. If it was renamed, update the check.")
        }
        var parens = 0
        var braces = 0
        var opened = false
        var inString = false
        var escaped = false
        var index = start.lowerBound
        while index < code.endIndex {
            let character = code[index]
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if !opened {
                if character == "(" { parens += 1 }
                if character == ")" { parens -= 1 }
                if character == "{", parens == 0 { opened = true; braces = 1 }
            } else if character == "{" {
                braces += 1
            } else if character == "}" {
                braces -= 1
                if braces == 0 { return String(code[start.lowerBound...index]) }
            }
            index = code.index(after: index)
        }
        throw Problem(description: "Source check: the braces after “\(signature)” don't balance, so the check can't read its body.")
    }

    static func count(of snippet: String, in code: String) -> Int {
        code.components(separatedBy: Self.code(snippet)).count - 1
    }
}

private func sourceCheckMessage(_ protects: String, _ snippet: String) -> String {
    "Source check: \(protects). Looked for: \(SourceCheck.code(snippet)). If you only reformatted or renamed, update this snippet to the equivalent code."
}

/// `code` (from `SourceCheck`) contains `snippet`, compared as code.
func assertSourceContains(_ code: String, _ snippet: String, _ protects: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(code.contains(SourceCheck.code(snippet)), sourceCheckMessage(protects, snippet), file: file, line: line)
}

/// `code` doesn't contain `snippet`, compared as code.
func assertSourceLacks(_ code: String, _ snippet: String, _ protects: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(code.contains(SourceCheck.code(snippet)), "Source check: \(protects). Found: \(SourceCheck.code(snippet)).", file: file, line: line)
}

/// `snippet` occurs exactly `times` times in `code`.
func assertSourceCount(_ code: String, _ snippet: String, _ times: Int, _ protects: String,
                       file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(SourceCheck.count(of: snippet, in: code), times, sourceCheckMessage(protects, snippet), file: file, line: line)
}

/// `first` occurs, then `second` occurs after it (each compared as code; the first occurrence of each).
func assertSourceOrder(_ code: String, _ first: String, before second: String, _ protects: String,
                       file: StaticString = #filePath, line: UInt = #line) {
    guard let a = code.range(of: SourceCheck.code(first)) else {
        return XCTFail(sourceCheckMessage(protects, first), file: file, line: line)
    }
    XCTAssertNotNil(code.range(of: SourceCheck.code(second), range: a.upperBound..<code.endIndex),
                    sourceCheckMessage(protects + " (it must come after: \(SourceCheck.code(first)))", second), file: file, line: line)
}
