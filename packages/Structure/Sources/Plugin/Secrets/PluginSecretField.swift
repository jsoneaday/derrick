import Foundation

/// Declared credential in `extensions.app.derrick.secrets`.
/// Labels are shown to the user. Values stay in Keychain, never in guest code.
public struct PluginSecretField: Codable, Sendable, Hashable {
    public let id: String
    public let label: String
    public let kind: Kind

    public enum Kind: String, Codable, Sendable, Hashable {
        case username
        case password
        case token
        case apiKey = "api_key"
    }

    public init(id: String, label: String, kind: Kind) throws {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.range(of: #"^[a-z][a-z0-9_]{0,31}$"#, options: .regularExpression) != nil else {
            throw PluginManifestError.invalidSecretField(
                "id '\(id)' must be 1–32 characters: start with a letter, then letters, numbers, or underscores."
            )
        }
        guard (1...80).contains(label.count) else {
            throw PluginManifestError.invalidSecretField("label is required and must be at most 80 characters.")
        }
        self.id = id
        self.label = label
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case id, label, kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try container.decode(String.self, forKey: .id),
            label: try container.decode(String.self, forKey: .label),
            kind: try container.decode(Kind.self, forKey: .kind)
        )
    }

    public var descriptor: PluginSecretDescriptor {
        PluginSecretDescriptor(id: id, label: label, kind: kind.rawValue)
    }

    public var jsonObject: [String: String] {
        ["id": id, "label": label, "kind": kind.rawValue]
    }

    public static func decode(_ json: PluginJSON) throws -> PluginSecretField {
        guard case .object(let object) = json else {
            throw PluginManifestError.invalidSecretField("each secrets entry must be an object")
        }
        func string(_ key: String) throws -> String {
            guard let value = object[key] else {
                throw PluginManifestError.invalidSecretField("missing \(key)")
            }
            guard case .string(let string) = value else {
                throw PluginManifestError.invalidSecretField("\(key) must be a string")
            }
            return string
        }
        let kindRaw = try string("kind").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let kind = Kind(rawValue: kindRaw) else {
            throw PluginManifestError.invalidSecretField(
                "kind must be username, password, token, or api_key"
            )
        }
        return try PluginSecretField(id: try string("id"), label: try string("label"), kind: kind)
    }

    public static func decodeList(_ json: PluginJSON?) throws -> [PluginSecretField] {
        guard let json else { return [] }
        guard case .array(let items) = json else {
            throw PluginManifestError.invalidFieldType("extensions.app.derrick.secrets")
        }
        var fields: [PluginSecretField] = []
        var seen = Set<String>()
        for item in items {
            let field = try decode(item)
            guard seen.insert(field.id).inserted else {
                throw PluginManifestError.invalidSecretField("duplicate secret id '\(field.id)'")
            }
            fields.append(field)
        }
        return fields
    }

    public static func fields(fromManifestJSON data: Data) -> [PluginSecretField] {
        (try? AgentPluginManifest.decode(data))?.derrick?.secrets ?? []
    }
}

public struct PluginSecretsRequiredError: Error, LocalizedError, Sendable {
    public let pluginID: String
    public let fields: [PluginSecretField]

    public init(pluginID: String, fields: [PluginSecretField]) {
        self.pluginID = pluginID
        self.fields = fields
    }

    public var errorDescription: String? {
        let labels = fields.map(\.label).joined(separator: ", ")
        return "Plugin '\(pluginID)' needs Keychain credentials: \(labels)."
    }
}
