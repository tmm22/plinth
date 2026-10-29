import Foundation

struct APIParameter: Hashable {
    let name: String
    let location: String
    let required: Bool
    let description: String
    let defaultValue: String
    let schemaJSON: String
}

struct Endpoint: Identifiable, Hashable {
    let id: String
    let method: String
    let path: String
    let title: String
    let group: String
    let description: String
    let parameters: [APIParameter]
    let bodyTemplate: String
    let bodySchema: String
    let requiresAuth: Bool
    var sessionOnly: Bool { path == "/apiKey" }
}

enum EndpointCatalog {
    /// Packaged apps keep the spec in `Contents/Resources`. Tests and `swift run` use the SwiftPM resource bundle. The package accessor fatal-errors when that bundle is missing, so it is only consulted after the app bundle lookup fails.
    static func specificationURL() -> URL? {
        if let packaged = Bundle.main.url(forResource: "openapi", withExtension: "json") {
            return packaged
        }
        return Bundle.module.url(forResource: "openapi", withExtension: "json")
    }

    static func load() -> [Endpoint] {
        guard let url = specificationURL(),
              let data = try? Data(contentsOf: url),
              let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let paths = document["paths"] as? [String: [String: Any]] else { return [] }
        let schemas = (document["components"] as? [String: Any])?["schemas"] as? [String: Any] ?? [:]
        func resolve(_ schema: [String: Any], depth: Int = 0) -> [String: Any] {
            guard depth < 12 else { return schema }
            if let ref = schema["$ref"] as? String,
               let source = schemas[String(ref.split(separator: "/").last ?? "")] as? [String: Any] {
                return resolve(source, depth: depth + 1)
            }
            var result = schema
            if let properties = schema["properties"] as? [String: [String: Any]] {
                result["properties"] = properties.mapValues { resolve($0, depth: depth + 1) }
            }
            if let items = schema["items"] as? [String: Any] { result["items"] = resolve(items, depth: depth + 1) }
            return result
        }
        func example(_ schema: [String: Any], depth: Int = 0) -> Any {
            guard depth < 12 else { return NSNull() }
            if let value = schema["default"] { return value }
            // A spec example is an illustration, not a value to send: an example string (such as `ownerId` "1" in
            // `PATCH /files`), or an example object or list holding them, is left empty for the user to fill in,
            // which `validateJSON` insists on where required. Number and boolean examples are kept.
            if let value = schema["example"] as? NSNumber { return value }
            if let values = schema["enum"] as? [Any], let value = values.first { return value }
            switch schema["type"] as? String {
            case "object":
                let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
                let required = schema["required"] as? [String] ?? []
                // Required fields plus explicitly defaulted fields make safe editable starting points.
                // Full optional fields remain visible in the adjacent schema.
                var names = Set(required)
                for (key, property) in properties where property["default"] != nil { names.insert(key) }
                if let itemTypes = properties["type"]?["enum"] as? [String], itemTypes.first == "PRINT", properties["publicFileServiceId"] != nil {
                    names.insert("publicFileServiceId")
                    names.insert("filamentId")
                    names.insert("quantity")
                }
                return Dictionary(uniqueKeysWithValues: names.compactMap { key -> (String, Any)? in
                    guard let property = properties[key] else { return nil }
                    return (key, example(property, depth: depth + 1))
                })
            case "array": return [example(schema["items"] as? [String: Any] ?? [:], depth: depth + 1)]
            case "integer", "number": return schema["minimum"] ?? 1
            case "boolean": return false
            default: return ""
            }
        }
        func pretty(_ value: Any) -> String {
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        var result: [Endpoint] = []
        for (path, operations) in paths {
            for (method, value) in operations where ["get", "post", "patch", "put", "delete"].contains(method) {
                guard let operation = value as? [String: Any] else { continue }
                let params = (operation["parameters"] as? [[String: Any]] ?? []).map { parameter -> APIParameter in
                    let schema = parameter["schema"] as? [String: Any] ?? [:]
                    let defaultValue = schema["default"].map { String(describing: $0) } ?? ""
                    let schemaJSON = pretty(schema)
                    return APIParameter(
                        name: parameter["name"] as? String ?? "",
                        location: parameter["in"] as? String ?? "query",
                        required: parameter["required"] as? Bool ?? false,
                        description: parameter["description"] as? String ?? "",
                        defaultValue: defaultValue,
                        schemaJSON: schemaJSON
                    )
                }
                let body = operation["requestBody"] as? [String: Any]
                let content = body?["content"] as? [String: Any]
                let json = content?["application/json"] as? [String: Any]
                let schema = (json?["schema"] as? [String: Any]).map { resolve($0) }
                let security = operation["security"] as? [[String: Any]]
                result.append(Endpoint(id: method.uppercased() + " " + path, method: method.uppercased(), path: path, title: operation["summary"] as? String ?? path, group: (operation["tags"] as? [String])?.first ?? "Other", description: operation["description"] as? String ?? "", parameters: params, bodyTemplate: schema.map { pretty(example($0)) } ?? "", bodySchema: schema.map { pretty($0) } ?? "", requiresAuth: security?.isEmpty != true))
            }
        }
        return result.sorted { ($0.group, $0.path, $0.method) < ($1.group, $1.path, $1.method) }
    }
}
