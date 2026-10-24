import Foundation

// MARK: - JSON values for the Claude API
//
// An ordered JSON value: objects keep their keys in the order they were written or read. Request bodies are
// therefore byte-for-byte stable from one request to the next (prompt caching matches on the exact prefix), and the
// tool inputs Claude writes are passed back in the order it wrote them. The parser is strict (RFC 8259) and bounded
// in depth; the writer never emits NaN or infinity.

struct AnthropicJSONMember: Equatable, Sendable {
    let key: String
    let value: AnthropicJSON
}

indirect enum AnthropicJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnthropicJSON])
    case object([AnthropicJSONMember])

    /// The member's value (the last one, if a key repeats), or nil for a missing key or a non-object.
    subscript(key: String) -> AnthropicJSON? {
        guard case .object(let members) = self else { return nil }
        return members.last(where: { $0.key == key })?.value
    }

    var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    var arrayValue: [AnthropicJSON]? { if case .array(let value) = self { return value }; return nil }
    var objectMembers: [AnthropicJSONMember]? { if case .object(let value) = self { return value }; return nil }
    var isNull: Bool { self == .null }
    /// Integers and integral doubles that fit an Int.
    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value.rounded() == value && abs(value) < 9.0e15: return Int(value)
        default: return nil
        }
    }
    var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    /// The same object with `key` set: replaced in place when present, appended otherwise. Non-objects are unchanged.
    func setting(_ key: String, to value: AnthropicJSON) -> AnthropicJSON {
        guard case .object(let members) = self else { return self }
        let replacement = AnthropicJSONMember(key: key, value: value)
        guard let first = members.firstIndex(where: { $0.key == key }) else { return .object(members + [replacement]) }
        var result: [AnthropicJSONMember] = []
        for (index, member) in members.enumerated() where member.key != key || index == first {
            result.append(index == first ? replacement : member)
        }
        return .object(result)
    }

    /// Builds an object from ordered pairs.
    static func fromPairs(_ pairs: [(String, AnthropicJSON)]) -> AnthropicJSON {
        .object(pairs.map { AnthropicJSONMember(key: $0.0, value: $0.1) })
    }
}

extension AnthropicJSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                         ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral,
                         ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(floatLiteral value: Double) { self = .double(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: AnthropicJSON...) { self = .array(elements) }
    /// Dictionary literals keep their written order, so schemas and request bodies read as they are written.
    init(dictionaryLiteral elements: (String, AnthropicJSON)...) { self = .object(elements.map { AnthropicJSONMember(key: $0.0, value: $0.1) }) }
    init(nilLiteral: ()) { self = .null }
}

// MARK: Writing

extension AnthropicJSON {
    /// Compact UTF-8 JSON with keys in their stored order.
    var encoded: Data { Data(encodedString.utf8) }

    var encodedString: String {
        var output = ""
        Self.write(self, into: &output)
        return output
    }

    private static func write(_ value: AnthropicJSON, into output: inout String) {
        switch value {
        case .null: output += "null"
        case .bool(let flag): output += flag ? "true" : "false"
        case .int(let number): output += String(number)
        case .double(let number):
            // JSON has no NaN or infinity; an integral double is written without a fraction.
            if !number.isFinite { output += "null" }
            else if number.rounded() == number, abs(number) < 1e15 { output += String(Int(number)) }
            else { output += "\(number)" }
        case .string(let text): writeString(text, into: &output)
        case .array(let items):
            output += "["
            for (index, item) in items.enumerated() {
                if index > 0 { output += "," }
                write(item, into: &output)
            }
            output += "]"
        case .object(let members):
            output += "{"
            for (index, member) in members.enumerated() {
                if index > 0 { output += "," }
                writeString(member.key, into: &output)
                output += ":"
                write(member.value, into: &output)
            }
            output += "}"
        }
    }

    private static func writeString(_ text: String, into output: inout String) {
        output += "\""
        // Most strings (base64 images above all) need no escaping.
        if !text.utf8.contains(where: { $0 < 0x20 || $0 == 0x22 || $0 == 0x5C }) {
            output += text
            output += "\""
            return
        }
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }
}

// MARK: Parsing

struct AnthropicJSONParseError: Error, Equatable {
    let offset: Int
    let reason: String
}

extension AnthropicJSON {
    static let maximumParseDepth = 256

    /// Strictly parses one JSON value; whitespace may surround it, nothing else may follow it.
    static func parse(_ data: Data) throws -> AnthropicJSON {
        var parser = AnthropicJSONParser(bytes: [UInt8](data))
        return try parser.parseDocument()
    }

    static func parse(_ text: String) throws -> AnthropicJSON {
        var parser = AnthropicJSONParser(bytes: Array(text.utf8))
        return try parser.parseDocument()
    }
}

private struct AnthropicJSONParser {
    let bytes: [UInt8]
    var position = 0
    var depth = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    func fail(_ reason: String) -> AnthropicJSONParseError { AnthropicJSONParseError(offset: position, reason: reason) }

    mutating func parseDocument() throws -> AnthropicJSON {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard position == bytes.count else { throw fail("Unexpected text after the JSON value") }
        return value
    }

    mutating func skipWhitespace() {
        while position < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[position]) { position += 1 }
    }

    mutating func parseValue() throws -> AnthropicJSON {
        guard position < bytes.count else { throw fail("Unexpected end of JSON") }
        switch bytes[position] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expectLiteral("true"); return .bool(true)
        case UInt8(ascii: "f"): try expectLiteral("false"); return .bool(false)
        case UInt8(ascii: "n"): try expectLiteral("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
        default: throw fail("Unexpected character")
        }
    }

    mutating func expectLiteral(_ literal: String) throws {
        let expected = Array(literal.utf8)
        guard position + expected.count <= bytes.count, Array(bytes[position..<position + expected.count]) == expected else {
            throw fail("Invalid literal")
        }
        position += expected.count
    }

    mutating func enter() throws {
        depth += 1
        guard depth <= AnthropicJSON.maximumParseDepth else { throw fail("JSON is nested too deeply") }
    }

    mutating func parseObject() throws -> AnthropicJSON {
        try enter()
        defer { depth -= 1 }
        position += 1
        var members: [AnthropicJSONMember] = []
        skipWhitespace()
        if position < bytes.count, bytes[position] == UInt8(ascii: "}") { position += 1; return .object(members) }
        while true {
            skipWhitespace()
            guard position < bytes.count, bytes[position] == UInt8(ascii: "\"") else { throw fail("Expected a key") }
            let key = try parseString()
            skipWhitespace()
            guard position < bytes.count, bytes[position] == UInt8(ascii: ":") else { throw fail("Expected ':'") }
            position += 1
            skipWhitespace()
            let value = try parseValue()
            members.append(AnthropicJSONMember(key: key, value: value))
            skipWhitespace()
            guard position < bytes.count else { throw fail("Unexpected end of object") }
            if bytes[position] == UInt8(ascii: ",") { position += 1; continue }
            if bytes[position] == UInt8(ascii: "}") { position += 1; return .object(members) }
            throw fail("Expected ',' or '}'")
        }
    }

    mutating func parseArray() throws -> AnthropicJSON {
        try enter()
        defer { depth -= 1 }
        position += 1
        var items: [AnthropicJSON] = []
        skipWhitespace()
        if position < bytes.count, bytes[position] == UInt8(ascii: "]") { position += 1; return .array(items) }
        while true {
            skipWhitespace()
            items.append(try parseValue())
            skipWhitespace()
            guard position < bytes.count else { throw fail("Unexpected end of array") }
            if bytes[position] == UInt8(ascii: ",") { position += 1; continue }
            if bytes[position] == UInt8(ascii: "]") { position += 1; return .array(items) }
            throw fail("Expected ',' or ']'")
        }
    }

    mutating func parseHex4() throws -> UInt32 {
        guard position + 4 <= bytes.count else { throw fail("Short \\u escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[position]
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
            default: throw fail("Invalid \\u escape")
            }
            value = value * 16 + digit
            position += 1
        }
        return value
    }

    mutating func parseString() throws -> String {
        position += 1 // opening quote
        var raw: [UInt8] = []
        while true {
            guard position < bytes.count else { throw fail("Unterminated string") }
            let byte = bytes[position]
            if byte == UInt8(ascii: "\"") { position += 1; break }
            if byte < 0x20 { throw fail("Control character in string") }
            if byte != UInt8(ascii: "\\") { raw.append(byte); position += 1; continue }
            position += 1
            guard position < bytes.count else { throw fail("Unterminated escape") }
            let escape = bytes[position]
            position += 1
            switch escape {
            case UInt8(ascii: "\""): raw.append(0x22)
            case UInt8(ascii: "\\"): raw.append(0x5C)
            case UInt8(ascii: "/"): raw.append(0x2F)
            case UInt8(ascii: "b"): raw.append(0x08)
            case UInt8(ascii: "f"): raw.append(0x0C)
            case UInt8(ascii: "n"): raw.append(0x0A)
            case UInt8(ascii: "r"): raw.append(0x0D)
            case UInt8(ascii: "t"): raw.append(0x09)
            case UInt8(ascii: "u"):
                var code = try parseHex4()
                if (0xD800...0xDBFF).contains(code) {
                    guard position + 2 <= bytes.count, bytes[position] == UInt8(ascii: "\\"), bytes[position + 1] == UInt8(ascii: "u") else {
                        throw fail("Unpaired surrogate")
                    }
                    position += 2
                    let low = try parseHex4()
                    guard (0xDC00...0xDFFF).contains(low) else { throw fail("Unpaired surrogate") }
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                } else if (0xDC00...0xDFFF).contains(code) {
                    throw fail("Unpaired surrogate")
                }
                guard let scalar = Unicode.Scalar(code) else { throw fail("Invalid code point") }
                raw.append(contentsOf: Array(String(Character(scalar)).utf8))
            default:
                throw fail("Invalid escape")
            }
        }
        guard let text = String(bytes: raw, encoding: .utf8) else { throw fail("Invalid UTF-8 in string") }
        return text
    }

    mutating func parseNumber() throws -> AnthropicJSON {
        let start = position
        var isInteger = true
        if bytes[position] == UInt8(ascii: "-") { position += 1 }
        guard position < bytes.count else { throw fail("Invalid number") }
        if bytes[position] == UInt8(ascii: "0") {
            position += 1
        } else if (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(bytes[position]) {
            while position < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[position]) { position += 1 }
        } else {
            throw fail("Invalid number")
        }
        if position < bytes.count, bytes[position] == UInt8(ascii: ".") {
            isInteger = false
            position += 1
            let digits = position
            while position < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[position]) { position += 1 }
            guard position > digits else { throw fail("Invalid number") }
        }
        if position < bytes.count, bytes[position] == UInt8(ascii: "e") || bytes[position] == UInt8(ascii: "E") {
            isInteger = false
            position += 1
            if position < bytes.count, bytes[position] == UInt8(ascii: "+") || bytes[position] == UInt8(ascii: "-") { position += 1 }
            let digits = position
            while position < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[position]) { position += 1 }
            guard position > digits else { throw fail("Invalid number") }
        }
        let text = String(decoding: bytes[start..<position], as: UTF8.self)
        if isInteger, let integer = Int(text) { return .int(integer) }
        guard let number = Double(text), number.isFinite else { throw fail("Number out of range") }
        return .double(number)
    }
}

// MARK: Schema checks

/// The first way `value` breaks `schema`, or nil when it fits. Covers the JSON Schema subset Studio's tools use:
/// `type` (a name or a list), `properties`, `required`, `additionalProperties: false`, `items`, `enum`, `const`,
/// `minimum`/`maximum`, `minItems`/`maxItems` and `minLength`/`maxLength`. Unknown keywords are ignored. Claude's
/// `strict` tools normally guarantee a fit, but streamed (`eager_input_streaming`) inputs aren't checked by the API.
func anthropicSchemaProblem(_ value: AnthropicJSON, schema: AnthropicJSON, path: String = "input") -> String? {
    guard case .object = schema else { return nil }
    if let allowed = schema["enum"]?.arrayValue, !allowed.contains(where: { anthropicJSONEqualForSchema($0, value) }) {
        return "\(path) isn’t one of the allowed values."
    }
    if let constant = schema["const"], !anthropicJSONEqualForSchema(constant, value) {
        return "\(path) isn’t the required value."
    }
    if let typeSpec = schema["type"] {
        let types = typeSpec.arrayValue?.compactMap(\.stringValue) ?? [typeSpec.stringValue].compactMap { $0 }
        if !types.isEmpty, !types.contains(where: { anthropicJSONMatchesType(value, $0) }) {
            return "\(path) should be \(types.joined(separator: " or "))."
        }
    }
    switch value {
    case .object(let members):
        let properties = schema["properties"]?.objectMembers ?? []
        for required in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where value[required] == nil {
            return "\(path).\(required) is missing."
        }
        let additionalAllowed = schema["additionalProperties"]?.boolValue ?? true
        for member in members {
            if let propertySchema = properties.last(where: { $0.key == member.key })?.value {
                if let problem = anthropicSchemaProblem(member.value, schema: propertySchema, path: "\(path).\(member.key)") { return problem }
            } else if !additionalAllowed {
                return "\(path).\(member.key) isn’t an expected field."
            } else if let additionalSchema = schema["additionalProperties"], case .object = additionalSchema,
                      let problem = anthropicSchemaProblem(member.value, schema: additionalSchema, path: "\(path).\(member.key)") {
                return problem
            }
        }
    case .array(let items):
        if let minimum = schema["minItems"]?.intValue, items.count < minimum { return "\(path) has too few items." }
        if let maximum = schema["maxItems"]?.intValue, items.count > maximum { return "\(path) has too many items." }
        if let itemSchema = schema["items"] {
            for (index, item) in items.enumerated() {
                if let problem = anthropicSchemaProblem(item, schema: itemSchema, path: "\(path)[\(index)]") { return problem }
            }
        }
    case .string(let text):
        if let minimum = schema["minLength"]?.intValue, text.count < minimum { return "\(path) is too short." }
        if let maximum = schema["maxLength"]?.intValue, text.count > maximum { return "\(path) is too long." }
    case .int, .double:
        if let number = value.doubleValue {
            if let minimum = schema["minimum"]?.doubleValue, number < minimum { return "\(path) is below \(anthropicSchemaNumber(minimum))." }
            if let maximum = schema["maximum"]?.doubleValue, number > maximum { return "\(path) is above \(anthropicSchemaNumber(maximum))." }
            if let minimum = schema["exclusiveMinimum"]?.doubleValue, number <= minimum { return "\(path) must be above \(anthropicSchemaNumber(minimum))." }
            if let maximum = schema["exclusiveMaximum"]?.doubleValue, number >= maximum { return "\(path) must be below \(anthropicSchemaNumber(maximum))." }
        }
    case .null, .bool:
        break
    }
    return nil
}

private func anthropicSchemaNumber(_ value: Double) -> String {
    value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : "\(value)"
}

private func anthropicJSONMatchesType(_ value: AnthropicJSON, _ type: String) -> Bool {
    switch (type, value) {
    case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null): return true
    case ("number", .int), ("number", .double): return true
    case ("integer", _): return value.intValue != nil && value.doubleValue != nil
    default: return false
    }
}

/// Numbers compare by value (1 and 1.0 match); everything else structurally.
private func anthropicJSONEqualForSchema(_ a: AnthropicJSON, _ b: AnthropicJSON) -> Bool {
    if let x = a.doubleValue, let y = b.doubleValue { return x == y }
    return a == b
}
