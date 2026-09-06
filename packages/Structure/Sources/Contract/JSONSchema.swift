import Foundation

/// JSON Schema subset for every bundled Derrick schema.
/// Supports type, const, enum, required, properties, additionalProperties,
/// items, minLength, minProperties, boolean schemas, `$defs`,
/// local `#/...` pointers, and sibling-file `$ref`s.
enum JSONSchema: Sendable {
    typealias DocumentLoader = (String) throws -> [String: Any]

    static func validate(
        instance: Any,
        schema: Any,
        root: [String: Any],
        loadDocument: DocumentLoader,
        path: String = "$"
    ) throws {
        if isBool(schema) {
            if jsonEqual(schema, true) { return }
            throw GuestContractError.validationFailed("\(path) is rejected by the schema.")
        }
        guard let schemaObject = jsonObject(schema) else {
            throw GuestContractError.validationFailed("\(path) schema is not an object.")
        }
        if let ref = schemaObject["$ref"] as? String {
            let resolved = try resolve(ref: ref, currentRoot: root, loadDocument: loadDocument)
            try validate(
                instance: instance,
                schema: resolved.schema,
                root: resolved.root,
                loadDocument: loadDocument,
                path: path
            )
            return
        }
        if let constValue = schemaObject["const"] {
            guard jsonEqual(instance, constValue) else {
                throw GuestContractError.validationFailed("\(path) must be \(describe(constValue)).")
            }
        }
        if let allowed = schemaObject["enum"] as? [Any] {
            guard allowed.contains(where: { jsonEqual(instance, $0) }) else {
                throw GuestContractError.validationFailed("\(path) is not an allowed enum value.")
            }
        }
        if let type = schemaObject["type"] {
            try checkType(instance, type: type, path: path)
        }
        if isJSONObject(instance), let object = jsonObject(instance) {
            if let rawMin = schemaObject["minProperties"],
               let minProperties = integerValue(rawMin),
               object.count < minProperties {
                throw GuestContractError.validationFailed(
                    "\(path) must have at least \(minProperties) properties."
                )
            }
            let properties = schemaObject["properties"] as? [String: Any] ?? [:]
            if let required = schemaObject["required"] as? [String] {
                for key in required where object[key] == nil {
                    throw GuestContractError.validationFailed("\(path) is missing required property \(key).")
                }
            }
            for (key, value) in object {
                if let propertySchema = properties[key] {
                    try validate(
                        instance: value,
                        schema: propertySchema,
                        root: root,
                        loadDocument: loadDocument,
                        path: "\(path).\(key)"
                    )
                    continue
                }
                let additional = schemaObject["additionalProperties"]
                if let additional, isBool(additional), jsonEqual(additional, false) {
                    throw GuestContractError.validationFailed("\(path) has unknown property \(key).")
                }
                if let additional, !isBool(additional) {
                    try validate(
                        instance: value,
                        schema: additional,
                        root: root,
                        loadDocument: loadDocument,
                        path: "\(path).\(key)"
                    )
                }
            }
        }
        if let itemsSchema = schemaObject["items"], let array = jsonArray(instance) {
            for (index, item) in array.enumerated() {
                try validate(
                    instance: item,
                    schema: itemsSchema,
                    root: root,
                    loadDocument: loadDocument,
                    path: "\(path)[\(index)]"
                )
            }
        }
        if let rawMinLength = schemaObject["minLength"],
           let minLength = integerValue(rawMinLength),
           let string = instance as? String,
           string.count < minLength {
            throw GuestContractError.validationFailed("\(path) is shorter than \(minLength) characters.")
        }
    }

    static func object(from data: Data, name: String) throws -> [String: Any] {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw GuestContractError.invalidJSON
        }
        guard let object = jsonObject(json) else {
            throw GuestContractError.invalidJSON
        }
        _ = name
        return object
    }

    private static func resolve(
        ref: String,
        currentRoot: [String: Any],
        loadDocument: DocumentLoader
    ) throws -> (root: [String: Any], schema: Any) {
        let document: [String: Any]
        let pointer: String
        if ref.hasPrefix("#") {
            document = currentRoot
            pointer = ref
        } else {
            let parts = ref.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            document = try loadDocument(String(parts[0]))
            pointer = parts.count > 1 ? "#\(parts[1])" : "#"
        }
        return (document, try pointerValue(pointer, in: document, ref: ref))
    }

    private static func pointerValue(_ pointer: String, in document: [String: Any], ref: String) throws -> Any {
        if pointer == "#" || pointer.isEmpty {
            return document
        }
        guard pointer.hasPrefix("#/") else {
            throw GuestContractError.validationFailed("Unsupported schema $ref \(ref).")
        }
        var node: Any = document
        for raw in pointer.dropFirst(2).split(separator: "/") {
            let part = unescapePointer(String(raw))
            if let object = jsonObject(node), let next = object[part] {
                node = next
                continue
            }
            if let array = jsonArray(node), let index = Int(part), index >= 0, index < array.count {
                node = array[index]
                continue
            }
            throw GuestContractError.validationFailed("Schema $ref \(ref) does not resolve.")
        }
        return node
    }

    private static func unescapePointer(_ value: String) -> String {
        value.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
    }

    private static func checkType(_ instance: Any, type: Any, path: String) throws {
        let allowed: [String]
        if let name = type as? String {
            allowed = [name]
        } else if let names = type as? [String] {
            allowed = names
        } else {
            return
        }
        guard allowed.contains(where: { matchesType(instance, $0) }) else {
            throw GuestContractError.validationFailed("\(path) has the wrong JSON type.")
        }
    }

    private static func matchesType(_ instance: Any, _ type: String) -> Bool {
        switch type {
        case "object":
            return isJSONObject(instance)
        case "array":
            return jsonArray(instance) != nil
        case "string":
            return instance is String
        case "integer":
            return integerValue(instance) != nil && !isBool(instance)
        case "number":
            return numberValue(instance) != nil && !isBool(instance)
        case "boolean":
            return isBool(instance)
        case "null":
            return instance is NSNull
        default:
            return true
        }
    }

    private static func isJSONObject(_ value: Any) -> Bool {
        jsonObject(value) != nil
    }

    private static func jsonObject(_ value: Any) -> [String: Any]? {
        if let object = value as? [String: Any] {
            return object
        }
        guard let object = value as? NSDictionary else { return nil }
        var result: [String: Any] = [:]
        for (key, item) in object {
            guard let string = key as? String else { return nil }
            result[string] = item
        }
        return result
    }

    private static func jsonArray(_ value: Any) -> [Any]? {
        if let array = value as? [Any] {
            return array
        }
        if let array = value as? NSArray {
            return array.map { $0 as Any }
        }
        return nil
    }

    private static func isBool(_ value: Any) -> Bool {
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        }
        return value is Bool
    }

    private static func integerValue(_ value: Any) -> Int? {
        if isBool(value) { return nil }
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func numberValue(_ value: Any) -> Double? {
        if isBool(value) { return nil }
        if let double = value as? Double { return double }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    private static func jsonEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        if isBool(lhs), isBool(rhs) {
            return (lhs as? Bool) == (rhs as? Bool)
                || ((lhs as? NSNumber)?.boolValue == (rhs as? NSNumber)?.boolValue)
        }
        if let left = lhs as? String, let right = rhs as? String { return left == right }
        if let left = integerValue(lhs), let right = integerValue(rhs) { return left == right }
        if let left = numberValue(lhs), let right = numberValue(rhs) { return left == right }
        return false
    }

    private static func describe(_ value: Any) -> String {
        if let string = value as? String { return "\"\(string)\"" }
        if isBool(value) { return String(describing: value) }
        if let number = numberValue(value) { return String(number) }
        return String(describing: value)
    }
}
