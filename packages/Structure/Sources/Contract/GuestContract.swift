import Foundation

/// Canonical JSON Schema catalog for guest I/O, connector protocol, and factory prompts.
/// Load, dump, and validate every bundled schema through this type.
public enum GuestContract: Sendable {
    public enum Schema: String, Sendable, CaseIterable {
        case hopEvent = "hop-event.schema.json"
        case envelopeList = "envelope-list.schema.json"
        case executionContextWire = "execution-context-wire.schema.json"
        case connectorContract = "connector-contract.schema.json"
        case connectorParams = "connector-params.schema.json"
        case connectorResultEmit = "connector-result-emit.schema.json"
        case connectorVendor = "connector-vendor.schema.json"
        case guestRuntime = "guest-runtime.schema.json"
        case workerProduct = "worker-product.schema.json"
        case webCrawlerResult = "web-crawler-result.schema.json"
        case fileExtractorResult = "file-extractor-result.schema.json"
        case newsReaderResult = "news-reader-result.schema.json"
        case scriptExecContract = "script-exec-contract.schema.json"
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

    public static func loadSchemaObject(_ schema: Schema) throws -> [String: Any] {
        try JSONSchema.object(from: try loadSchemaData(schema), name: schema.rawValue)
    }

    public static func validate(_ instance: Any, against schema: Schema) throws {
        let root = try loadSchemaObject(schema)
        try JSONSchema.validate(
            instance: instance,
            schema: root,
            root: root,
            loadDocument: loadSiblingSchema(named:),
            path: "$"
        )
    }

    public static func validate(json data: Data, against schema: Schema) throws {
        let instance: Any
        do {
            instance = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw GuestContractError.invalidJSON
        }
        try validate(instance, against: schema)
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

    private static func loadSiblingSchema(named fileName: String) throws -> [String: Any] {
        guard let schema = Schema(rawValue: fileName) else {
            throw GuestContractError.validationFailed("Unknown schema $ref \(fileName).")
        }
        return try loadSchemaObject(schema)
    }

    private static func nestedStringEnum(schema: Schema, path: [String]) throws -> [String] {
        var node: Any = try loadSchemaObject(schema)
        for key in path {
            guard let object = node as? [String: Any], let next = object[key] else {
                throw GuestContractError.invalidJSON
            }
            node = next
        }
        if let values = (node as? [String: Any])?["enum"] as? [String] {
            return values
        }
        if let field = node as? [String: Any], let values = field["enum"] as? [String] {
            return values
        }
        throw GuestContractError.invalidJSON
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

enum SchemaEnumLoader {
    static func stringEnum(
        from data: Data,
        property: String,
        arrayPath: [String] = []
    ) throws -> [String] {
        guard var node = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GuestContractError.invalidJSON
        }
        for key in arrayPath {
            guard let next = node[key] as? [String: Any] else {
                throw GuestContractError.invalidJSON
            }
            node = next
        }
        guard let properties = node["properties"] as? [String: Any],
              let field = properties[property] as? [String: Any],
              let values = field["enum"] as? [String] else {
            throw GuestContractError.invalidJSON
        }
        return values
    }
}
