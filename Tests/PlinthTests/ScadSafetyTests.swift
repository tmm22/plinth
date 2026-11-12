import XCTest
@testable import Plinth

// ScadSafety's round 6 gaps: the old DXF modules and `file =` argument, `\x`/`\u`/`\U` escapes decoded before the
// path check, and path-like text anywhere in a string.

final class ScadSafetyTests: XCTestCase {
    func testDXFModulesAreRefused() {
        for code in [#"dxf_linear_extrude(file = "a.dxf", height = 2);"#,
                     #"dxf_rotate_extrude(origin = [0, 0]);"#,
                     #"x = dxf_dim(name = "w"); cube(x);"#,
                     #"p = dxf_cross(layer = "c"); cube(1);"#] {
            let problem = scadSafetyProblem(code)
            XCTAssertNotNil(problem, code)
        }
        XCTAssertTrue(scadSafetyProblem("dxf_dim(name = \"w\");")?.contains("DXF") == true)
        // Only the whole word counts.
        XCTAssertNil(scadSafetyProblem("my_dxf_dim = 3; cube(my_dxf_dim);"))
    }

    func testFileArgumentIsRefusedEvenBehindComments() {
        XCTAssertNotNil(scadSafetyProblem("linear_extrude(height = 2, file = name) square(1);"))
        XCTAssertNotNil(scadSafetyProblem("rotate_extrude(file /* hidden */ = n);"))
        XCTAssertNotNil(scadSafetyProblem("rotate_extrude(file // hidden\n = n);"))
        XCTAssertNotNil(scadSafetyProblem("file=3; cube(file);"))
        XCTAssertTrue(scadSafetyScan("linear_extrude(file\n=\nx);").usesFileArgument)
        // A comparison, other names and the word in a comment or string are fine.
        XCTAssertFalse(scadSafetyScan("if (file == 3) cube(1);").usesFileArgument)
        XCTAssertNil(scadSafetyProblem("profile = 3; files = 2; cube(profile + files);"))
        XCTAssertNil(scadSafetyProblem("// file = x\ntext(\"file = x\"); cube(1);"))
    }

    func testEscapesAreDecodedBeforeThePathCheck() {
        XCTAssertEqual(scadSafetyScan(#"a = "\x41B\U000043";"#).strings, ["ABC"])
        XCTAssertEqual(scadSafetyScan(#"a = "90°";"#).strings, ["90°"])
        XCTAssertNil(scadSafetyProblem(#"text("90°"); cube(1);"#))
        XCTAssertNotNil(scadSafetyProblem(#"echo("\x2Fetc\x2Fpasswd"); cube(1);"#))
        XCTAssertNotNil(scadSafetyProblem(#"echo("/etc"); cube(1);"#))
        XCTAssertNotNil(scadSafetyProblem(#"echo("\U00002Fetc"); cube(1);"#))
        XCTAssertNotNil(scadSafetyProblem(#"echo("\x2E\x2E\x2Fsecret"); cube(1);"#))
        XCTAssertNotNil(scadSafetyProblem(#"echo("part\x2Estl"); cube(1);"#))
        // A malformed escape keeps its backslash, which the path check refuses.
        XCTAssertEqual(scadSafetyScan(#"a = "\xZZ";"#).strings, [#"\xZZ"#])
        XCTAssertNotNil(scadSafetyProblem(#"echo("\xZZ"); cube(1);"#))
        XCTAssertNotNil(scadSafetyProblem(#"echo("\u12"); cube(1);"#))
    }

    func testHexEscapeForms() {
        func digits(_ text: String) -> ArraySlice<Unicode.Scalar> { ArraySlice(Array(text.unicodeScalars)) }
        XCTAssertEqual(scadSafetyHexEscape("x", digits: digits("2Fz"))?.scalar, "/")
        XCTAssertEqual(scadSafetyHexEscape("x", digits: digits("2Fz"))?.length, 2)
        XCTAssertNil(scadSafetyHexEscape("x", digits: digits("80")), "\\x goes up to 7F")
        XCTAssertEqual(scadSafetyHexEscape("u", digits: digits("00e9"))?.scalar, "é")
        XCTAssertNil(scadSafetyHexEscape("u", digits: digits("D800")), "a lone surrogate isn't a character")
        XCTAssertEqual(scadSafetyHexEscape("U", digits: digits("01F600"))?.length, 6)
        XCTAssertNil(scadSafetyHexEscape("U", digits: digits("110000")))
        XCTAssertNil(scadSafetyHexEscape("u", digits: digits("12")))
        XCTAssertNil(scadSafetyHexEscape("n", digits: digits("1234")))
    }

    func testPathLikeTextAnywhereInAStringIsRefused() {
        for text in ["/etc/passwd", "~/x", "~me", "x/..", "..", "a/../b", "../Users", "C:/Windows"] {
            XCTAssertTrue(scadSafetyLooksLikePath(text), text)
        }
        // Label text that only looks like folders stays allowed: it can't leave OpenSCAD's empty temporary folder.
        for text in ["1/2 inch", "and/or", "24/7", "Users", "home", "W/H", "Work/Home", "Recycling/Bin", "Office/Private"] {
            XCTAssertFalse(scadSafetyLooksLikePath(text), text)
        }
        XCTAssertNil(scadSafetyProblem("text(\"use 1/2 inch\", font = \"Liberation Sans:style=Bold\"); cube(1);"))
    }

    // MARK: Round 21: OpenSCAD 2021.01's other ways to read a file

    func testOpenSCAD2021ImportModulesAreRefused() {
        for code in [#"import_stl("a");"#,
                     "import_off(p);",
                     "import_dxf(file = p);",
                     #"import_stl(str(chr(47), "etc", chr(47), "hosts"));"#,
                     "import_stl /* c */ (p);",
                     "2import_off(p);"] {
            let problem = scadSafetyProblem(code)
            XCTAssertNotNil(problem, code)
            XCTAssertTrue(problem?.contains("reads files") == true, code)
        }
        // Only the whole word counts.
        XCTAssertNil(scadSafetyProblem("my_import_stl = 2; cube(my_import_stl);"))
        XCTAssertNil(scadSafetyProblem("import_stl_size = 2; cube(import_stl_size);"))
    }

    func testUnnamedExtrudeArgumentsAreRefused() {
        let refused = [
            "linear_extrude(p) square(1);",
            #"linear_extrude(str(chr(47),"etc",chr(47),"hosts")) square(1);"#,
            "linear_extrude(height = 2, p) square(1);",
            "linear_extrude(h) square(1);",
            "linear_extrude ( /* c */ p ) square(1);",
            "linear_extrude // c\n(p) square(1);",
            "linear_extrude(2 + h) square(1);",
            "linear_extrude(height == 2) square(1);",
            "linear_extrude(height <= 2) square(1);",
            "linear_extrude(2, 3) square(1);",
            "linear_extrude(2, p) square(1);",
            "linear_extrude(-2) square(1);",
            "linear_extrude(12abc) square(1);",
            "linear_extrude(1e5x) square(1);",
            "linear_extrude((p)) square(1);",
            "linear_extrude([p][0]) square(1);",
            "linear_extrude(height = max(1, 2), p) square(1);",
            "linear_extrude(height = [1, 2][0], center = true, p) square(1);",
            "linear_extrude(height = let(a = 1) a, p) square(1);",
            "linear_extrude(,p) square(1);",
            "#linear_extrude(p) square(1);",
            "translate([0, 0, 1]) linear_extrude(p) square(1);",
            "linear_extrude(height = 1) linear_extrude(p) square(1);",
            "linear_extrude 1e999 (p) square(1);",
            "linear_extrude(height 1e999 = 2, p) square(1);",
            "module m(q) linear_extrude(q) square(1); m(\"x\");",
            "rotate_extrude(360) square(1);",
            "rotate_extrude(p) square(1);",
            "rotate_extrude(angle = 90, p) square(1);",
            "rotate_extrude(angle = 90, convexity = 2, 3) square(1);",
        ]
        for code in refused {
            let problem = scadSafetyProblem(code)
            XCTAssertNotNil(problem, code)
            XCTAssertTrue(problem?.contains("unnamed argument") == true, "\(code): \(problem ?? "nil")")
        }
        XCTAssertEqual(scadSafetyScan("rotate_extrude(p) square(1);").unnamedExtrudeArgument, "rotate_extrude")
        XCTAssertEqual(scadSafetyScan("cube(1); linear_extrude(p) square(1);").unnamedExtrudeArgument, "linear_extrude")

        let allowed = [
            "linear_extrude(1) text(label);",
            "linear_extrude(2.5, center = true) square(1);",
            "linear_extrude(.5) square(1);",
            "linear_extrude(1e1) square(1);",
            "linear_extrude(2 /* mm */, center = true) square(1);",
            "linear_extrude(height = max(1, h), center = true, twist = 0) square(1);",
            "linear_extrude(height = [1, 2][0]) square(1);",
            "linear_extrude(height = h > 2 ? h : 2, $fn = 32) square(1);",
            "linear_extrude(height = 2, scale = [1, 1.5], slices = 10, ) square(1);",
            "linear_extrude() square(1);",
            "linear_extrude ( height = 2 ) square(1);",
            "linear_extrude(\n  height = 2, // the base\n  center = true\n) square(1);",
            "rotate_extrude(angle = 360, convexity = 4, $fn = 64) square(1);",
            "rotate_extrude() square(1);",
            "rotate_extrude($fn = 96) translate([10, 0]) circle(r = 2);",
            "translate([0, 0, 1]) rotate([0, 90, 0]) linear_extrude(height = 2) polygon([[0, 0], [1, 0], [0, 1]]);",
            // Other modules may take unnamed arguments as before.
            "cube([1, 2, 3], true); cylinder(5, 2, 1); text(\"Hi\", 5);",
            // The names alone, and other calls named like them, are fine.
            "my_linear_extrude = 2; cube(my_linear_extrude);",
            "module my_rotate_extrude(r) rotate_extrude(angle = 360) circle(r); my_rotate_extrude(3);",
        ]
        for code in allowed {
            XCTAssertNil(scadSafetyProblem(code), code)
        }
    }

    func testNonASCIIOutsideStringsAndCommentsIsRefused() {
        for code in ["linear_extrude(file\u{00A0}= p) square(1);",
                     "cube(1);\u{FEFF}",
                     "\u{FEFF}cube(1);",
                     "cube\u{00A0}(1);",
                     "x = 2;\u{2003}cube(x);",
                     "caf\u{00E9} = 2; cube(1);",
                     "cube(1)\u{037E}"] { // A Greek question mark looks like a semicolon.
            let problem = scadSafetyProblem(code)
            XCTAssertNotNil(problem, code)
            XCTAssertTrue(problem?.contains("ASCII") == true, code)
        }
        XCTAssertNil(scadSafetyProblem(#"text("90°"); cube(1);"#))
        XCTAssertNil(scadSafetyProblem("// café\ncube(1);"))
        XCTAssertNil(scadSafetyProblem("/* größe: 5 mm\u{00A0}*/ cube(5);"))
        XCTAssertNil(scadSafetyProblem("text(\"Zoë\u{00A0}& José\"); cube(1);"))
    }

    func testFileArgumentStaysRefusedAcrossDroppedNumbers() {
        // OpenSCAD 2021.01 silently drops a number it can't convert, so a number between `file` and `=` mustn't hide it.
        XCTAssertNotNil(scadSafetyProblem("file 1e999 = 3; cube(1);"))
        XCTAssertTrue(scadSafetyScan("rotate_extrude(file 2 = n);").usesFileArgument)
        XCTAssertFalse(scadSafetyScan("if (file != 3) cube(1);").usesFileArgument)
        XCTAssertFalse(scadSafetyScan("if (file >= 3) cube(1);").usesFileArgument)
    }

    func testRawLineBreaksInAStringDontHideAPath() {
        // OpenSCAD 2021.01 drops a line break typed straight into a string, so "⏎/etc/hosts" is "/etc/hosts" there.
        XCTAssertTrue(scadSafetyLooksLikePath("\n/etc/hosts"))
        XCTAssertTrue(scadSafetyLooksLikePath("\r\n~/x"))
        XCTAssertTrue(scadSafetyLooksLikePath("part.s\ntl"))
        XCTAssertNotNil(scadSafetyProblem("echo(\"\n/etc/hosts\"); cube(1);"))
        XCTAssertFalse(scadSafetyLooksLikePath("Line one\nLine two"))
        XCTAssertFalse(scadSafetyLooksLikePath("1/2\ninch"))
    }

    func testALoneCarriageReturnCantEndACommentEarly() {
        // OpenSCAD keeps a lone CR inside a `//` comment, so this would run `surface(…)` while looking commented out.
        let hidden = "cube(1); // x\r/*\nsurface(file = \"/Users/someone/Desktop/photo.png\");\n// */\n"
        XCTAssertNotNil(scadSafetyProblem(hidden))
        XCTAssertNotNil(scadSafetyProblem("cube(1); // note\rinclude <x.scad>\n"))
        XCTAssertNotNil(scadSafetyProblem("cube(1);\r"))
        XCTAssertTrue(scadSafetyHasLoneCarriageReturn("a\rb"))
        XCTAssertFalse(scadSafetyHasLoneCarriageReturn("a\r\nb\r\n"))
        // Windows line endings still pass.
        XCTAssertNil(scadSafetyProblem("// A stand\r\nwidth = 40;\r\ncube([width, 10, 2]);\r\n"))
    }

    func testWorkbenchRefusesATemplateDesignedWithClaude() {
        let claude = "// \(scadClaudeTemplateLinePrefix) the Plinth app.\nwidth = 40;\ncube([width, 10, 2]);\n"
        XCTAssertTrue(scadTemplateIsClaudeWritten(claude))
        XCTAssertEqual(workbenchOpenSCADBodyRefusal(["scadCode": claude]), scadClaudeTemplateSlantRefusal)
        XCTAssertNil(workbenchOpenSCADBodyRefusal(["scadCode": "width = 40;\ncube([width, 10, 2]);"]))
        XCTAssertNil(workbenchOpenSCADBodyRefusal(nil))
        XCTAssertNil(workbenchOpenSCADBodyRefusal(["other": claude]))
    }

    func testTokensSkipCommentsAndJoinOperators() {
        let tokens: [ScadSafetyToken] = [.identifier("a"), .symbol("=="), .number, .symbol("&&"), .identifier("b"),
                                         .symbol("<="), .number, .symbol(";")]
        XCTAssertNil(scadSafetyUnnamedExtrudeArgument(tokens))
        XCTAssertFalse(scadSafetyAssignsFile(tokens))
        XCTAssertTrue(scadSafetyAssignsFile([.identifier("file"), .symbol("=")]))
        XCTAssertEqual(scadSafetyUnnamedExtrudeArgument([.identifier("linear_extrude"), .symbol("("), .string, .symbol(")")]),
                       "linear_extrude")
        XCTAssertNil(scadSafetyUnnamedExtrudeArgument([.identifier("linear_extrude"), .symbol("("), .number, .symbol(")")]))
        XCTAssertEqual(scadSafetyUnnamedExtrudeArgument([.identifier("rotate_extrude"), .symbol("("), .number, .symbol(")")]),
                       "rotate_extrude")
    }
}
