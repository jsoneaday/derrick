import Foundation

/// Minimal JSON value for envelope payloads.
public enum PluginJSON: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([PluginJSON])
    case object([String: PluginJSON])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([PluginJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: PluginJSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

enum PluginDecoding {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw unwrap(error)
        }
    }

    static func unwrap(_ error: Error) -> Error {
        if let manifest = error as? PluginManifestError { return manifest }
        switch error as? DecodingError {
        case .dataCorrupted(let ctx),
             .keyNotFound(_, let ctx),
             .typeMismatch(_, let ctx),
             .valueNotFound(_, let ctx):
            if let underlying = ctx.underlyingError {
                return unwrap(underlying)
            }
        default:
            break
        }
        return error
    }
}
