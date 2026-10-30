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
}
