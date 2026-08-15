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

    public init(from decoder: Decoder) throws {
        let raw = try PluginJSON(from: decoder)
        guard case .object(let object) = raw else {
            throw PluginEnvelopeError.notAnObject
        }
        if case .number(let value) = object["schema_version"] {
            schemaVersion = Int(value)
        } else {
            schemaVersion = PluginContract.envelopeSchemaVersion
        }
        var rest = object
        rest.removeValue(forKey: "schema_version")
        let verbRaw = rest["verb"]?.stringValue ?? rest["type"]?.stringValue
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
        if let verbRaw {
            guard let parsed = PluginVerb.parse(verbRaw) else {
                throw PluginEnvelopeError.unknownVerb(verbRaw)
            }
            verb = parsed
        } else if let inferred = PluginVerb.infer(from: rest) {
            verb = inferred
        } else {
            throw PluginEnvelopeError.unknownVerb("(missing)")
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

public enum PluginEnvelopeError: Error, Equatable, LocalizedError {
    case unknownVerb(String)
    case notAnObject
    case notAnArray
    case invalidJSON(String)

    public var errorDescription: String? {
        switch self {
        case .unknownVerb(let v):
            return "Unknown plugin verb: \(v)"
        case .notAnObject:
            return "Envelope must be a JSON object"
        case .notAnArray:
            return "handle() must return a JSON array of envelopes"
        case .invalidJSON(let preview):
            return "handle() stdout was not JSON: \(preview)"
        }
    }
}

public enum PluginEnvelopeList {
    /// Guest stdout must be a JSON array of envelope objects. Strings and bare objects fail.
    public static func decode(_ data: Data) throws -> [PluginEnvelope] {
        let trimmed = data.drop(while: { $0 == 0x20 || $0 == 0x0a || $0 == 0x0d || $0 == 0x09 })
        guard !trimmed.isEmpty else {
            throw PluginEnvelopeError.notAnArray
        }
        let json: PluginJSON
        do {
            json = try JSONDecoder().decode(PluginJSON.self, from: data)
        } catch {
            let preview = String(decoding: data.prefix(180), as: UTF8.self)
            throw PluginEnvelopeError.invalidJSON(preview)
        }
        guard case .array(let items) = json else {
            throw PluginEnvelopeError.notAnArray
        }
        return try items.map { item in
            guard case .object = item else {
                throw PluginEnvelopeError.notAnObject
            }
            let encoded = try JSONEncoder().encode(item)
            return try JSONDecoder().decode(PluginEnvelope.self, from: encoded)
        }
    }
}
