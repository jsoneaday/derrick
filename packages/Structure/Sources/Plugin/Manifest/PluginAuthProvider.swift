import Foundation

/// Named auth handle on a plugin. Secrets stay in the host Keychain.
/// `provider` is a plugin-chosen label, not a host vendor catalog.
public struct PluginAuthRef: Codable, Sendable, Hashable {
    public var name: String
    public var provider: String

    public init(name: String, provider: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64,
              name.range(of: #"^[A-Za-z][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil else {
            throw PluginManifestError.invalidAuthRefName(name)
        }
        guard !provider.isEmpty, provider.count <= 64 else {
            throw PluginManifestError.unknownAuthProvider(provider)
        }
        self.name = name
        self.provider = provider
    }

    enum CodingKeys: String, CodingKey {
        case name, provider
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let provider = try container.decode(String.self, forKey: .provider)
        try self.init(name: name, provider: provider)
    }
}
