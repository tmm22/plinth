import XCTest
@testable import Plinth

/// The app is called Plinth. Text shown to the seller names it "Plinth"; text sent only to Claude says "the app", and
/// the Claude prompts say once that Plinth is the app (not the plinth tool, a base under a model).
final class AppNameCopyTests: XCTestCase {
    private let studioWord = try! NSRegularExpression(pattern: "(?<![A-Za-z_])Studio(?![A-Za-z_])")

    private func mentionsStudio(_ text: String) -> Bool {
        let rest = text.replacingOccurrences(of: "Bambu Studio", with: "")
        return studioWord.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) != nil
    }

    // MARK: Order template

    func testTheOrderTemplateIsNamedAndStillDetectedByItsColumns() throws {
        XCTAssertEqual(OrderImportFormat.template.title, "Plinth order template")
        // Detection reads the header columns, never the title: the file Save Template… writes still parses as the template.
        let template = orderImportTemplateCSV()
        XCTAssertFalse(template.contains("Plinth"), "The template file itself carries no app name")
        let parse = try orderImportParse(data: Data(template.utf8))
        XCTAssertEqual(parse.format, .template)
        XCTAssertEqual(parse.format.rawValue, "csv", "Drafts' source metadata is unchanged")
        // A minimal template file with just the header and one row.
        let row = ["A1", "Ada Lovelace", "ada@example.com", "1 Main St", "", "Springfield", "IL", "62701", "US", "SKU-1", "1"]
        let text = orderImportTemplateHeader.joined(separator: ",") + "\n" + row.joined(separator: ",") + "\n"
        XCTAssertEqual(try orderImportParse(data: Data(text.utf8)).format, .template)
    }

    // MARK: Exported .scad header

    func testTheSavedTemplateHeaderNamesTheAppAndIsIgnoredAsAValue() {
        let code = "width = 40; // [10:1:100] Width (mm)\nheight = 5; // [1:1:20] Height (mm)\ncube([width, 20, height]);\n"
        let file = accessoryTemplateFileText(code: code, name: "Phone stand")
        XCTAssertTrue(file.hasPrefix("// Phone stand\n// Designed with Claude in the Plinth app. Check every measurement on a test print before selling.\n"), file)
        XCTAssertFalse(mentionsStudio(file))
        // Personalise from Template reads the same values with or without the header.
        XCTAssertEqual(scadTemplateParameters(file).parameters.map(\.name), ["width", "height"])
        XCTAssertEqual(scadTemplateParameters(file).parameters.map(\.name), scadTemplateParameters(code).parameters.map(\.name))
    }

    // MARK: Claude-facing text

    func testThePrintReviewPromptSaysTheAppAndDefinesTheName() {
        XCTAssertFalse(mentionsStudio(printReviewSystemPrompt))
        XCTAssertTrue(printReviewSystemPrompt.contains("the app's own measurements"))
        XCTAssertTrue(printReviewSystemPrompt.contains("a Mac app called Plinth"))
        XCTAssertTrue(printReviewSystemPrompt.contains("(in the app's own messages, Plinth means the app; the plinth tool below, and a plinth the seller mentions, is a base under a model)"))
        // The honesty rule is kept.
        XCTAssertTrue(printReviewSystemPrompt.contains("Say the app's checks found no problems only when its measurements say so."))
        XCTAssertFalse(mentionsStudio(printReviewPlanTool.description))
        XCTAssertTrue(printReviewPlanTool.description.contains("the app's tools"))
        let text = printReviewUserText(viewTitles: [], factLines: ["Size: 1"], contextLines: ["Purpose: Display"])
        XCTAssertFalse(mentionsStudio(text))
        XCTAssertTrue(text.contains("The app’s measurements:"))
        XCTAssertTrue(text.contains("What the app knows about the model:"))
    }

    func testTheAccessoryPromptsSayTheAppAndDefineTheName() {
        XCTAssertFalse(mentionsStudio(accessorySystemPrompt))
        XCTAssertTrue(accessorySystemPrompt.contains("The seller works in a Mac app called Plinth. In the app's own messages, Plinth means the app; in the seller's words, a plinth may be a base under a model, so read it in context."))
        XCTAssertTrue(accessorySystemPrompt.contains("The app renders it with OpenSCAD"))
        for tool in accessoryTools {
            XCTAssertFalse(mentionsStudio(tool.description), tool.name)
        }
        XCTAssertFalse(mentionsStudio(accessorySuggestTool.description))
        XCTAssertTrue(accessorySuggestTool.description.contains("The app shows the ideas"))
    }

    func testTheSeenChecksLineSaysPlinth() {
        XCTAssertTrue(printReviewNoProblemsLine.hasPrefix("Plinth’s checks found no problems:"))
        XCTAssertTrue(replicaNoProblemsLine.hasPrefix("Plinth’s checks found no problems:"))
    }

    // MARK: Source scan

    /// Every string literal in the app's sources: no "Slant Studio", and "Studio" as a word only in "Bambu Studio".
    /// Identifiers such as `studioDraftId` or `StudioStore` aren't words, so they don't count.
    func testNoStringLiteralInTheSourcesNamesTheOldApp() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Plinth")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50, "The scan must read the app's sources: \(sources.path)")
        var literalCount = 0
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for literal in swiftStringLiterals(source) {
                literalCount += 1
                // The move from Slant Studio has to name the old app; only LegacyMigration.swift may, and only as
                // "Slant Studio" (never "Studio" alone for this app).
                if file.lastPathComponent == "LegacyMigration.swift" {
                    let withoutOldName = literal.text.replacingOccurrences(of: "Slant Studio", with: "")
                    XCTAssertFalse(mentionsStudio(withoutOldName), "\(file.lastPathComponent):\(literal.line): \(literal.text)")
                    continue
                }
                XCTAssertFalse(literal.text.contains("Slant Studio"), "\(file.lastPathComponent):\(literal.line): \(literal.text)")
                XCTAssertFalse(mentionsStudio(literal.text), "\(file.lastPathComponent):\(literal.line): \(literal.text)")
            }
        }
        XCTAssertGreaterThan(literalCount, 1000, "The scan must find the string literals")
    }

    func testTheLiteralScannerFindsStudioWhereverItHides() {
        let source = #"""
        let a = "Plain Studio text"
        // "Studio in a comment"
        /* "Studio in a block comment" */
        let b = """
            first line \
            Studio on a continued line
            """
        let c = "x \(f("Studio inside an interpolation")) y"
        let d = #"raw "Studio" text"#
        let e = "Bambu Studio and studioDraftId and StudioStore"
        """#
        let flagged = swiftStringLiterals(source).filter { mentionsStudio($0.text) }.map(\.line)
        XCTAssertEqual(Set(flagged), [1, 6, 8, 9])
    }
}

/// The text of each string literal (one entry per source line of a multi-line literal), with its line number. Comments
/// are skipped; strings inside interpolations are found too. Enough of Swift's grammar for the app's sources.
func swiftStringLiterals(_ source: String) -> [(line: Int, text: String)] {
    let chars = Array(source)
    var result: [(line: Int, text: String)] = []
    var i = 0
    var line = 1

    func starts(_ text: String, at index: Int) -> Bool {
        var k = index
        for character in text {
            guard k < chars.count, chars[k] == character else { return false }
            k += 1
        }
        return true
    }

    /// Reads a literal whose opening delimiter starts at `start`; returns the index after its closing delimiter.
    func readLiteral(from start: Int) -> Int {
        var j = start
        var hashes = 0
        while j < chars.count, chars[j] == "#" { hashes += 1; j += 1 }
        let multiline = starts("\"\"\"", at: j)
        j += multiline ? 3 : 1
        let close = (multiline ? "\"\"\"" : "\"") + String(repeating: "#", count: hashes)
        let escape = "\\" + String(repeating: "#", count: hashes)
        var buffer = ""
        var segmentLine = line
        while j < chars.count {
            if starts(close, at: j) { j += close.count; break }
            if starts(escape, at: j) {
                let next = j + escape.count
                if next < chars.count, chars[next] == "(" {
                    // Interpolation: scan to the matching parenthesis, reading nested literals.
                    var depth = 1
                    var k = next + 1
                    while k < chars.count, depth > 0 {
                        if chars[k] == "\"" || (chars[k] == "#" && k + 1 < chars.count && (chars[k + 1] == "\"" || chars[k + 1] == "#")) {
                            k = readLiteral(from: k)
                            continue
                        }
                        if chars[k] == "(" { depth += 1 }
                        if chars[k] == ")" { depth -= 1 }
                        if chars[k] == "\n" { line += 1 }
                        k += 1
                    }
                    buffer += "\\(…)"
                    j = k
                    continue
                }
                if next < chars.count, chars[next] == "\n" {
                    result.append((segmentLine, buffer)); buffer = ""
                    line += 1; segmentLine = line
                    j = next + 1
                    continue
                }
                buffer += String(chars[j..<min(next + 1, chars.count)])
                j = next + 1
                continue
            }
            if chars[j] == "\n" {
                result.append((segmentLine, buffer)); buffer = ""
                line += 1; segmentLine = line
            } else {
                buffer.append(chars[j])
            }
            j += 1
        }
        result.append((segmentLine, buffer))
        return j
    }

    while i < chars.count {
        if starts("//", at: i) {
            while i < chars.count, chars[i] != "\n" { i += 1 }
            continue
        }
        if starts("/*", at: i) {
            i += 2
            while i < chars.count, !starts("*/", at: i) {
                if chars[i] == "\n" { line += 1 }
                i += 1
            }
            i += 2
            continue
        }
        if chars[i] == "\n" { line += 1; i += 1; continue }
        if chars[i] == "\"" || (chars[i] == "#" && i + 1 < chars.count && (chars[i + 1] == "\"" || chars[i + 1] == "#")) {
            var k = i
            while k < chars.count, chars[k] == "#" { k += 1 }
            if k < chars.count, chars[k] == "\"" {
                i = readLiteral(from: i)
                continue
            }
        }
        i += 1
    }
    return result
}
