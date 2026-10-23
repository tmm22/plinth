import XCTest
@testable import SlantStudio

final class PersonalisationTests: XCTestCase {
    // MARK: Template values

    private let keychain = #"""
    // Keychain template
    /* [Text] */
    // The name on the keychain
    name = "Emma \"Em\" O\\Neil"; // 12
    // Font size in mm
    size = 12.5; // [5:30]
    font = "Liberation Sans"; // [Liberation Sans, DejaVu Serif:Serif]
    loop = true;
    count = -3e2;
    url = "http://example.com"; // a link, not a comment
    /* [Hidden] */
    secret = "hidden";
    /* [Shape] */
    corner = 2; // [1, 2, 4]
    $fn = 64;
    points = [1, 2, 3];
    expr = size * 2;
    two = 1; three = 3;
    module tag() { inner = "no"; text(name); }
    after = "module started";
    """#

    func testDetectsTopLevelLiteralsWithDescriptionsGroupsAndConstraints() {
        let template = scadTemplateParameters(keychain)
        XCTAssertEqual(template.parameters.map(\.name), ["name", "size", "font", "loop", "count", "url", "corner"])
        let name = template.parameters[0]
        XCTAssertEqual(name.kind, .string)
        XCTAssertEqual(name.defaultValue, #"Emma "Em" O\Neil"#)
        XCTAssertEqual(name.description, "The name on the keychain")
        XCTAssertEqual(name.group, "Text")
        XCTAssertEqual(name.maxLength, 12)
        XCTAssertEqual(name.line, 4)
        let size = template.parameters[1]
        XCTAssertEqual(size.kind, .number)
        XCTAssertEqual(size.defaultValue, "12.5")
        XCTAssertEqual(size.range, 5...30)
        XCTAssertEqual(size.description, "Font size in mm")
        XCTAssertEqual(template.parameters[2].choices, [ScadChoice(value: "Liberation Sans", label: "Liberation Sans"),
                                                        ScadChoice(value: "DejaVu Serif", label: "Serif")])
        XCTAssertEqual(template.parameters[3].kind, .boolean)
        XCTAssertEqual(template.parameters[3].defaultValue, "true")
        XCTAssertNil(template.parameters[3].description, "a blank-free line above that isn't a comment gives no description")
        XCTAssertEqual(template.parameters[4].defaultValue, "-3e2")
        // `//` inside a string isn't a comment; a trailing non-constraint comment becomes the description.
        XCTAssertEqual(template.parameters[5].defaultValue, "http://example.com")
        XCTAssertEqual(template.parameters[5].description, "a link, not a comment")
        // A group after [Hidden] shows values again.
        XCTAssertEqual(template.parameters[6].group, "Shape")
        XCTAssertEqual(template.parameters[6].choices.map(\.value), ["1", "2", "4"])
        XCTAssertFalse(template.usesOtherFiles)
        XCTAssertTrue(template.endsCleanly)
    }

    func testStringEscapesDecode() {
        let template = scadTemplateParameters(#"a = "tab\tline\nq\x41é\U01F600\z";"#)
        XCTAssertEqual(template.parameters.first?.defaultValue, "tab\tline\nqAé😀\\z")
    }

    func testIgnoresValuesInsideBlocksCommentsAndAfterDefinitions() {
        let source = """
        /* a = 1;
           b = 2; */
        c = 3;
        if (true) {
          d = 4;
        }
        e = 5;
        function f(x) = x;
        g = 6;
        """
        XCTAssertEqual(scadTemplateParameters(source).parameters.map(\.name), ["c", "e"])
    }

    func testDefaultMissingFromChoicesIsOffered() {
        let template = scadTemplateParameters("size = 3; // [1, 2]")
        XCTAssertEqual(template.parameters.first?.choices.map(\.value), ["3", "1", "2"])
    }

    func testRepeatedAssignmentKeepsLastDefault() {
        let template = scadTemplateParameters("label = \"One\";\nlabel = \"Two\";")
        XCTAssertEqual(template.parameters.count, 1)
        XCTAssertEqual(template.parameters.first?.defaultValue, "Two")
    }

    func testDetectsIncludesAndUncleanEndings() {
        XCTAssertTrue(scadTemplateParameters("include <fonts.scad>\nname = \"A\";").usesOtherFiles)
        XCTAssertTrue(scadTemplateParameters("use<lib.scad>").usesOtherFiles)
        XCTAssertFalse(scadTemplateParameters("user = \"A\";").usesOtherFiles)
        XCTAssertFalse(scadTemplateParameters("name = \"A\";\n/* never closed").endsCleanly)
        XCTAssertFalse(scadTemplateParameters("module m() {").endsCleanly)
        XCTAssertTrue(scadTemplateParameters("name = \"A\"; // ok").endsCleanly)
        let unterminated = scadTemplateParameters("broken = \"unterminated;\nnext = 1;")
        XCTAssertTrue(unterminated.parameters.isEmpty, "the open string swallows the next line")
        XCTAssertFalse(unterminated.endsCleanly)
    }

    func testMalformedLinesAreIgnored() {
        for line in ["name = ;", "name \"A\";", "= 3;", "9x = 3;", "x == 3;", "x = 3", "x = 3; y", "x = 1.;", "x = 0x10;", "x = tru;", "x = \"a\" \"b\";"] {
            XCTAssertTrue(scadTemplateParameters(line).parameters.isEmpty, line)
        }
        XCTAssertTrue(scadTemplateParameters("").parameters.isEmpty)
    }

    func testCRLFTemplates() {
        let template = scadTemplateParameters("// Name\r\nname = \"A\";\r\n")
        XCTAssertEqual(template.parameters.first?.description, "Name")
    }

    // MARK: Values and arguments

    func testValueProblems() {
        let template = scadTemplateParameters(keychain)
        let name = template.parameters[0], size = template.parameters[1], font = template.parameters[2]
        XCTAssertNil(scadValueProblem("Ava", for: name))
        XCTAssertNotNil(scadValueProblem("Thirteen chars", for: name), "over the template's 12-character limit")
        XCTAssertNotNil(scadValueProblem("A\u{0}B", for: name))
        XCTAssertNotNil(scadValueProblem("A\u{7}B", for: name))
        XCTAssertNil(scadValueProblem(" 20 ", for: size))
        XCTAssertNotNil(scadValueProblem("40", for: size), "outside [5:30]")
        XCTAssertNotNil(scadValueProblem("12mm", for: size))
        XCTAssertNotNil(scadValueProblem("1e999", for: size))
        XCTAssertNil(scadValueProblem("DejaVu Serif", for: font))
        XCTAssertNotNil(scadValueProblem("Comic Sans", for: font))
        let free = scadTemplateParameters("t = \"\";").parameters[0]
        XCTAssertNotNil(scadValueProblem(String(repeating: "a", count: scadMaximumTextLength + 1), for: free))
        XCTAssertNil(scadValueProblem("Line one\nLine two\tend", for: free))
    }

    func testLiteralEscapingCannotEscapeTheString() {
        let hostile = #"Emma"; cube(1000); x = "\"#
        let literal = scadLiteral(hostile, kind: .string)
        XCTAssertEqual(literal, #""Emma\"; cube(1000); x = \"\\""#)
        // Read back with the template parser, it is one string with the original text.
        let parsed = scadParseAssignment("name = \(literal);")
        XCTAssertEqual(parsed?.value, .string(hostile))
        XCTAssertEqual(scadLiteral("a\nb\r\u{1}", kind: .string), #""a\nb\r\x01""#)
        XCTAssertEqual(scadLiteral(" 12 ", kind: .number), "12")
        XCTAssertEqual(scadLiteral("true", kind: .boolean), "true")
        XCTAssertEqual(scadLiteral("anything", kind: .boolean), "false")
    }

    func testOpenSCADArgumentsAreOneArgumentPerValue() {
        let parameters = scadTemplateParameters("name = \"A\";\nsize = 10;\nloop = false;").parameters
        let assignments = scadAssignments(parameters, values: ["name": "Mary Jane's \"tag\"", "size": "12"])
        XCTAssertEqual(openSCADArguments(templatePath: "/t/key chain.scad", outputPath: "/o/model.stl", assignments: assignments), [
            "-o", "/o/model.stl",
            "-D", #"name="Mary Jane's \"tag\"""#,
            "-D", "size=12",
            "-D", "loop=false",
            "/t/key chain.scad"
        ])
    }

    func testSourceForSlantAppendsAssignments() {
        let assignments = [ScadAssignment(name: "name", literal: "\"B\"")]
        XCTAssertEqual(scadSourceWithAssignments("name = \"A\"; // last line", assignments: assignments),
                       "name = \"A\"; // last line\nname = \"B\";\n")
        XCTAssertEqual(scadSourceWithAssignments("x = 1;\n", assignments: assignments), "x = 1;\nname = \"B\";\n")
        XCTAssertEqual(scadSourceWithAssignments("x = 1;", assignments: []), "x = 1;")
        // The appended line is read back as the new value.
        let combined = scadSourceWithAssignments("name = \"A\";", assignments: assignments)
        XCTAssertEqual(scadTemplateParameters(combined).parameters.first?.defaultValue, "B")
    }

    // MARK: Naming

    func testPersonalisedModelNames() {
        let parameters = scadTemplateParameters("name = \"Name\";\nline2 = \"\";\nsize = 10;").parameters
        XCTAssertEqual(personalisedModelName(templateName: "Keychain", parameters: parameters, values: ["name": "Emma"]), "Keychain – Emma")
        XCTAssertEqual(personalisedModelName(templateName: "Keychain", parameters: parameters,
                                             values: ["name": "Ann/Bo: Ltd", "line2": "Line\ntwo  "]), "Keychain – Ann-Bo- Ltd, Line two")
        XCTAssertEqual(personalisedModelName(templateName: "Keychain", parameters: parameters, values: ["size": "12"]), "Keychain – size 12")
        XCTAssertEqual(personalisedModelName(templateName: "Keychain", parameters: parameters, values: ["name": "Name"]), "Keychain")
        XCTAssertEqual(personalisedModelName(templateName: "..hidden.scad", parameters: [], values: [:]), "hidden")
        XCTAssertEqual(personalisedModelName(templateName: "  ", parameters: [], values: [:]), "Template")
        let long = personalisedModelName(templateName: String(repeating: "T", count: 90), parameters: parameters,
                                         values: ["name": String(repeating: "N", count: 300)])
        XCTAssertLessThanOrEqual(long.count, maximumModelNameLength)
        XCTAssertTrue(long.hasSuffix("…"))
        for name in ["Keychain – Emma", long, personalisedModelName(templateName: "a:b", parameters: parameters, values: ["name": "\u{7}x"])] {
            XCTAssertNotNil(validatedModelName(name), name)
            // The library takes the name from the file name, so it must survive the round trip.
            XCTAssertEqual((exportFileName(modelName: name, fileExtension: "stl") as NSString).deletingPathExtension, name)
        }
    }

    // MARK: Quota

    func testQuotaCountsFivePerHourOneInFlight() {
        var quota = OpenSCADQuota()
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(quota.remaining(now: start), 5)
        XCTAssertTrue(quota.begin(now: start))
        XCTAssertNotNil(quota.blockedReason(now: start), "one in flight")
        XCTAssertFalse(quota.begin(now: start))
        quota.finish()
        for minute in 1...4 {
            XCTAssertTrue(quota.begin(now: start.addingTimeInterval(Double(minute) * 60)))
            quota.finish()
        }
        let later = start.addingTimeInterval(10 * 60)
        XCTAssertEqual(quota.remaining(now: later), 0)
        XCTAssertFalse(quota.begin(now: later))
        XCTAssertEqual(quota.nextAvailable(now: later), start.addingTimeInterval(3600))
        XCTAssertNotNil(quota.blockedReason(now: later))
        // An hour after the first send, one slot frees up.
        let hourOn = start.addingTimeInterval(3600)
        XCTAssertEqual(quota.remaining(now: hourOn), 1)
        XCTAssertNil(quota.blockedReason(now: hourOn))
        XCTAssertTrue(quota.begin(now: hourOn))
        quota.finish()
        XCTAssertEqual(quota.remaining(now: hourOn), 0)
    }

    func testQuotaClockMovingBackStillCounts() {
        var quota = OpenSCADQuota()
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertTrue(quota.begin(now: now))
        quota.finish()
        XCTAssertEqual(quota.remaining(now: now.addingTimeInterval(-7200)), 4)
    }

    func testRateLimitedQuotaBlocksUntilReset() {
        var quota = OpenSCADQuota()
        let now = Date(timeIntervalSince1970: 3_000_000)
        quota.noteRateLimited(until: openSCADRateLimitedUntil(retryAfter: "120", rateLimitReset: nil, now: now))
        XCTAssertEqual(quota.remaining(now: now), 5)
        XCTAssertNotNil(quota.blockedReason(now: now))
        XCTAssertFalse(quota.begin(now: now))
        XCTAssertNil(quota.blockedReason(now: now.addingTimeInterval(121)))
        XCTAssertEqual(openSCADRateLimitedUntil(retryAfter: nil, rateLimitReset: nil, now: now), now.addingTimeInterval(3600))
        XCTAssertEqual(openSCADRateLimitedUntil(retryAfter: "999999", rateLimitReset: nil, now: now), now.addingTimeInterval(3600))
        XCTAssertEqual(openSCADRateLimitedUntil(retryAfter: "soon", rateLimitReset: nil, now: now), now.addingTimeInterval(3600))
    }

    func testEngineBlockedReasons() {
        let clean = scadTemplateParameters("name = \"A\";")
        let now = Date()
        XCTAssertEqual(personalisationDefaultEngine(localAvailable: true), .local)
        XCTAssertEqual(personalisationDefaultEngine(localAvailable: false), .slant)
        XCTAssertNil(personalisationEngineBlockedReason(.local, localAvailable: true, hasKey: false, template: clean, sourceBytes: 10, quota: OpenSCADQuota(), now: now))
        XCTAssertNotNil(personalisationEngineBlockedReason(.local, localAvailable: false, hasKey: true, template: clean, sourceBytes: 10, quota: OpenSCADQuota(), now: now))
        XCTAssertNil(personalisationEngineBlockedReason(.slant, localAvailable: false, hasKey: true, template: clean, sourceBytes: 10, quota: OpenSCADQuota(), now: now))
        XCTAssertNotNil(personalisationEngineBlockedReason(.slant, localAvailable: true, hasKey: false, template: clean, sourceBytes: 10, quota: OpenSCADQuota(), now: now))
        let includes = scadTemplateParameters("include <x.scad>\nname = \"A\";")
        XCTAssertNotNil(personalisationEngineBlockedReason(.slant, localAvailable: true, hasKey: true, template: includes, sourceBytes: 10, quota: OpenSCADQuota(), now: now))
        XCTAssertNil(personalisationEngineBlockedReason(.local, localAvailable: true, hasKey: true, template: includes, sourceBytes: 10, quota: OpenSCADQuota(), now: now))
        let open = scadTemplateParameters("name = \"A\";\n/*")
        XCTAssertNotNil(personalisationEngineBlockedReason(.slant, localAvailable: true, hasKey: true, template: open, sourceBytes: 10, quota: OpenSCADQuota(), now: now))
        XCTAssertNotNil(personalisationEngineBlockedReason(.slant, localAvailable: true, hasKey: true, template: clean, sourceBytes: scadMaximumTemplateBytes + 1, quota: OpenSCADQuota(), now: now))
    }

    func testOpenSCADAppCandidates() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let paths = openSCADAppCandidates(homeDirectory: home).map(\.path)
        XCTAssertEqual(paths.first, "/Applications/OpenSCAD.app")
        XCTAssertTrue(paths.contains("/Users/someone/Applications/OpenSCAD.app"))
    }

    func testErrorSummaryPrefersErrorLine() {
        XCTAssertEqual(openSCADErrorSummary("WARNING: x\nERROR: Parser error in file, line 3\nExecution aborted\n"),
                       "ERROR: Parser error in file, line 3")
        XCTAssertEqual(openSCADErrorSummary("one\n\ntwo  \n"), "two")
        XCTAssertNil(openSCADErrorSummary("\n \n"))
    }

    func testSectionsFollowTemplateOrder() {
        let parameters = scadTemplateParameters("a = 1;\n/* [One] */\nb = 2;\nc = 3;\n/* [Two] */\nd = 4;").parameters
        XCTAssertEqual(personalisationSections(parameters).map(\.title), [nil, "One", "Two"])
        XCTAssertEqual(personalisationSections(parameters).map { $0.parameters.map(\.name) }, [["a"], ["b", "c"], ["d"]])
        XCTAssertNil(personalisationValuesProblem(parameters, values: [:]))
        XCTAssertNotNil(personalisationValuesProblem(parameters, values: ["c": "x"]))
    }

    // MARK: Generated STL

    private let asciiTriangle = "solid t\n facet normal 0 0 1\n  outer loop\n   vertex 0 0 0\n   vertex 10 0 0\n   vertex 0 10 0\n  endloop\n endfacet\nendsolid t\n"

    func testGeneratedSTLIsCheckedAndReencoded() throws {
        let data = try personalisedSTLData(Data(asciiTriangle.utf8))
        XCTAssertEqual(try STLMesh.parse(data).triangleCount, 1)
        XCTAssertEqual(data.count, 84 + 50, "binary STL")
        XCTAssertThrowsError(try personalisedSTLData(Data()))
        XCTAssertThrowsError(try personalisedSTLData(Data(#"{"error":"bad"}"#.utf8)))
    }

    // MARK: Local process

    private func script(_ body: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PersonalisationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("fake-openscad")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testLocalRunPassesArgumentsAndReadsOutput() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PersonalisationArgs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let argsFile = folder.appendingPathComponent("args.txt")
        let fake = try script("""
        printf '%s\\n' "$@" > '\(argsFile.path)'
        out=""
        while [ $# -gt 0 ]; do
          if [ "$1" = "-o" ]; then out="$2"; shift; fi
          shift
        done
        printf '\(asciiTriangle.replacingOccurrences(of: "\n", with: "\\n"))' > "$out"
        """)
        let template = folder.appendingPathComponent("key chain.scad")
        try "name = \"A\";".write(to: template, atomically: true, encoding: .utf8)
        let assignments = [ScadAssignment(name: "name", literal: scadLiteral("O'Neil \"$HOME\" `x`", kind: .string))]
        let data = try await runOpenSCADProcess(executable: fake, templateURL: template, assignments: assignments)
        XCTAssertEqual(try STLMesh.parse(data).triangleCount, 1)
        let args = try String(contentsOf: argsFile, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(args.count, 5)
        XCTAssertEqual(args[0], "-o")
        XCTAssertEqual(args[2], "-D")
        XCTAssertEqual(args[3], #"name="O'Neil \"$HOME\" `x`""#, "no shell expands or splits the value")
        XCTAssertEqual(args[4], template.path)
    }

    func testLocalRunReportsFailureAndMissingOutput() async throws {
        let failing = try script("echo 'ERROR: Parser error in file' >&2\nexit 1\n")
        let template = FileManager.default.temporaryDirectory.appendingPathComponent("t.scad")
        do {
            _ = try await runOpenSCADProcess(executable: failing, templateURL: template, assignments: [])
            XCTFail("should fail")
        } catch let error as OpenSCADRunError {
            XCTAssertEqual(error, .failed(status: 1, summary: "ERROR: Parser error in file"))
        }
        let silent = try script("exit 0\n")
        do {
            _ = try await runOpenSCADProcess(executable: silent, templateURL: template, assignments: [])
            XCTFail("should fail")
        } catch let error as OpenSCADRunError {
            XCTAssertEqual(error, .noOutput(nil))
        }
    }

    func testLocalRunTimesOutAndStopsOnLargeOutput() async throws {
        let slow = try script("exec sleep 30\n")
        let template = FileManager.default.temporaryDirectory.appendingPathComponent("t.scad")
        let started = Date()
        do {
            _ = try await runOpenSCADProcess(executable: slow, templateURL: template, assignments: [], timeout: 0.3)
            XCTFail("should time out")
        } catch let error as OpenSCADRunError {
            XCTAssertEqual(error, .timedOut(0.3))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let chatty = try script("while true; do echo 'spam spam spam spam spam spam spam spam'; done\n")
        do {
            _ = try await runOpenSCADProcess(executable: chatty, templateURL: template, assignments: [], timeout: 20, maxLogBytes: 10_000)
            XCTFail("should stop")
        } catch let error as OpenSCADRunError {
            XCTAssertEqual(error, .outputTooLarge)
        }
    }

    func testLocalRunStopsWhenCancelled() async throws {
        let slow = try script("exec sleep 30\n")
        let template = FileManager.default.temporaryDirectory.appendingPathComponent("t.scad")
        let task = Task { try await runOpenSCADProcess(executable: slow, templateURL: template, assignments: []) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let started = Date()
        do {
            _ = try await task.value
            XCTFail("should be cancelled")
        } catch let error as OpenSCADRunError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // MARK: Import Orders personalisation

    func testPersonalisationFromEtsyVariations() {
        XCTAssertEqual(orderImportPersonalisation(options: "Personalization:Emma", column: ""), "Emma")
        XCTAssertEqual(orderImportPersonalisation(options: "Colour:Red,Personalization:Emma Rose,Size:Large", column: ""), "Emma Rose")
        XCTAssertEqual(orderImportPersonalisation(options: "Size:Small, personalisation : Jo & Sam ", column: ""), "Jo & Sam")
        XCTAssertEqual(orderImportPersonalisation(options: "Personalization:Not requested on this item.", column: ""), "")
        XCTAssertEqual(orderImportPersonalisation(options: "Colour:Red", column: ""), "")
        XCTAssertEqual(orderImportPersonalisation(options: "Colour:Personalization red", column: ""), "", "not a label")
        XCTAssertEqual(orderImportPersonalisation(options: "Personalization:Emma", column: " Ava "), "Ava", "a dedicated column wins")
        XCTAssertEqual(orderImportPersonalisation(options: "", column: "Not requested on this item"), "")
        var item = OrderImportItem(sku: "K", quantityText: "1", itemName: "Keychain", row: 2)
        item.options = "Personalization:Emma"; item.personalisation = "Emma"
        XCTAssertFalse(orderImportPersonalisationShowsOptions(item))
        item.options = "Colour:Red,Personalization:Emma"
        XCTAssertTrue(orderImportPersonalisationShowsOptions(item))
    }

    func testEtsyFileCarriesPersonalisationIntoItemsOnly() throws {
        let etsy = """
        Sale Date,Item Name,Buyer,Quantity,Price,Order ID,Date Shipped,Ship Name,Ship Address1,Ship Address2,Ship City,Ship State,Ship Zipcode,Ship Country,Variations,SKU
        10/01/26,Keychain,ana,1,10.00,555,,Ana Lee,1 Main St,,Austin,TX,78701,United States,"Colour:Blue,Personalization:Ana &amp; Ben",KEY
        10/01/26,Keychain,ana,1,10.00,555,,Ana Lee,1 Main St,,Austin,TX,78701,United States,Personalization:Not requested on this item.,KEY
        10/01/26,Desk Tidy,ben,1,10.00,556,,Ben Ng,2 High St,,Leeds,,LS1 1AA,United Kingdom,,TIDY
        """
        let parse = try orderImportParse(data: Data(etsy.utf8))
        XCTAssertEqual(parse.format, .etsy)
        XCTAssertEqual(parse.orders[0].items.map(\.personalisation), ["Ana & Ben", ""])
        XCTAssertEqual(parse.orders[0].items[0].options, "Colour:Blue,Personalization:Ana & Ben")
        XCTAssertEqual(parse.orders[1].items.map(\.personalisation), [""])
        XCTAssertTrue(parse.orders[0].repeatedRows.isEmpty, "different personalisation isn't a repeated row")
        XCTAssertEqual(orderImportPersonalisationList(parse.orders), "555 · Keychain: Ana & Ben")
        var multiline = parse.orders[0]
        multiline.items[1].personalisation = "Line 1\nLine 2"
        multiline.items[1].itemName = ""
        XCTAssertEqual(orderImportPersonalisationList([multiline]), "555 · Keychain: Ana & Ben\n555: Line 1 / Line 2")
        XCTAssertFalse(orderImportPersonalisationList(parse.orders).contains("Ana Lee"), "no recipient names")
        // Older Etsy files without Variations still load.
        let plain = etsy.replacingOccurrences(of: ",Variations", with: "")
            .replacingOccurrences(of: #","Colour:Blue,Personalization:Ana &amp; Ben""#, with: "")
            .replacingOccurrences(of: ",Personalization:Not requested on this item.", with: "")
            .replacingOccurrences(of: "United Kingdom,,", with: "United Kingdom,")
        XCTAssertEqual(try orderImportParse(data: Data(plain.utf8)).orders[0].items.map(\.personalisation), ["", ""])
    }

    func testTemplateAndDedicatedColumnsAreRead() throws {
        let csv = """
        order_id,name,email,line1,line2,city,state,zip,country,sku,quantity,Personalisation
        A1,Ana,ana@example.com,1 Main St,,Austin,TX,78701,US,KEY,1,Zoë
        """
        XCTAssertEqual(try orderImportParse(data: Data(csv.utf8)).orders[0].items.first?.personalisation, "Zoë")
    }
}
