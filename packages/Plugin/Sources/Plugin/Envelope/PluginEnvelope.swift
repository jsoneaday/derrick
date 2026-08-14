import Foundation

/// One guest → host envelope. Extra verbs are rejected at decode.
public struct PluginEnvelope: Codable, Sendable, Hashable {
    public var schemaVersion: Int
    public var verb: PluginVerb
    public var payload: [String: PluginJSON]

    public init(schemaVersion: Int = PluginContract.envelopeSchemaVersion, verb: PluginVerb, payload: [String: PluginJSON] = [:]) {
        self.schemaVersion = schemaVersion
        self.verb = verb
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case verb
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? PluginContract.envelopeSchemaVersion
        let verbRaw = try container.decodeIfPresent(String.self, forKey: .verb)
            ?? container.decodeIfPresent(String.self, forKey: .type)
        guard let verbRaw, let parsed = PluginVerb.parse(verbRaw) else {
            throw PluginEnvelopeError.unknownVerb(verbRaw ?? "(missing)")
        }
        verb = parsed
        let raw = try PluginJSON(from: decoder)
        guard case .object(let object) = raw else {
            throw PluginEnvelopeError.notAnObject
        }
        var rest = object
        rest.removeValue(forKey: "schema_version")
        rest.removeValue(forKey: "verb")
        rest.removeValue(forKey: "type")
        for nestKey in ["data", "result", "payload"] {
            if case .object(let nested)? = rest[nestKey] {
                rest.removeValue(forKey: nestKey)
                for (key, value) in nested where rest[key] == nil {
                    rest[key] = value
                }
            }
        }
        payload = rest
    }

    public func encode(to encoder: Encoder) throws {
        var object: [String: PluginJSON] = payload
        object["schema_version"] = .number(Double(schemaVersion))
        object["verb"] = .string(verb.rawValue)
        try PluginJSON.object(object).encode(to: encoder)
    }
}

private enum RawVerbKey: String, CodingKey {
    case verb
}

public enum PluginEnvelopeError: Error, Equatable, LocalizedError {
    case unknownVerb(String)
    case notAnObject
    case notAnArray

    public var errorDescription: String? {
        switch self {
        case .unknownVerb(let v):
            return "Unknown plugin verb: \(v)"
        case .notAnObject:
            return "Envelope must be a JSON object"
        case .notAnArray:
            return "handle() must return a JSON array of envelopes"
        }
    }
}

public enum PluginEnvelopeList {
    public static func decode(_ data: Data) throws -> [PluginEnvelope] {
        let json = try JSONDecoder().decode(PluginJSON.self, from: data)
        guard case .array(let items) = json else {
            throw PluginEnvelopeError.notAnArray
        }
        return try items.map { item in
            let encoded = try JSONEncoder().encode(item)
            return try JSONDecoder().decode(PluginEnvelope.self, from: encoded)
        }
    }
}
