import Foundation

/// Canonical JSON Schema paths for the language-agnostic guest ↔ host contract.
public enum GuestContract: Sendable {
    public enum Schema: String, Sendable, CaseIterable {
        case hopEvent = "hop-event.schema.json"
        case envelopeList = "envelope-list.schema.json"
        case executionContextWire = "execution-context-wire.schema.json"
    }

    public static func loadSchemaText(_ schema: Schema) throws -> String {
        let data = try loadSchemaData(schema)
        guard let text = String(data: data, encoding: .utf8) else {
            throw GuestContractError.invalidSchemaEncoding(schema)
        }
        return text
    }

    public static func loadSchemaData(_ schema: Schema) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: schema.rawValue,
            withExtension: nil,
            subdirectory: "schemas"
        ) else {
            throw GuestContractError.missingSchema(schema)
        }
        return try Data(contentsOf: url)
    }

    public static func officialEnvelopeVerbs(from schema: Schema = .envelopeList) throws -> [String] {
        try SchemaEnumLoader.stringEnum(from: loadSchemaData(schema), property: "verb", arrayPath: ["items"])
    }

    public static func officialHopEventKinds(from schema: Schema = .hopEvent) throws -> [String] {
        try SchemaEnumLoader.stringEnum(from: loadSchemaData(schema), property: "kind")
    }

    public static func officialWorkflowKinds() throws -> [String] {
        try nestedStringEnum(
            schema: .executionContextWire,
            path: ["properties", "workflow", "properties", "kind"]
        )
    }

    public static func officialExecutionContextCapabilities() throws -> [String] {
        try nestedStringEnum(
            schema: .executionContextWire,
            path: ["properties", "capabilities", "items"]
        )
    }

    public static func officialExecutionContextDeliveryModes() throws -> [String] {
        try nestedStringEnum(
            schema: .executionContextWire,
            path: ["properties", "delivery"]
        )
    }

    private static func nestedStringEnum(schema: Schema, path: [String]) throws -> [String] {
        guard var node = try JSONSerialization.jsonObject(with: loadSchemaData(schema)) as? [String: Any] else {
            throw GuestContractError.invalidJSON
        }
        for key in path.dropLast() {
            guard let next = node[key] as? [String: Any] else {
                throw GuestContractError.invalidJSON
            }
            node = next
        }
        guard let field = node[path.last!] as? [String: Any],
              let values = field["enum"] as? [String] else {
            throw GuestContractError.invalidJSON
        }
        return values
    }
}

public enum GuestContractError: Error, Equatable, LocalizedError {
    case missingSchema(GuestContract.Schema)
    case invalidSchemaEncoding(GuestContract.Schema)
    case invalidJSON
    case validationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingSchema(let schema):
            return "Missing bundled guest contract schema \(schema.rawValue)."
        case .invalidSchemaEncoding(let schema):
            return "Guest contract schema \(schema.rawValue) is not valid UTF-8."
        case .invalidJSON:
            return "Guest contract payload is not valid JSON."
        case .validationFailed(let message):
            return message
        }
    }
}
