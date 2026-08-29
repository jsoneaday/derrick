import Foundation

/// Closed Agent Plugins 1.0 `plugin.json`. Derrick fields are not top-level.
public struct AgentPluginManifest: Sendable, Hashable {
    public var schema: String
    public var name: PluginID
    public var version: String?
    public var description: String?
    public var author: AgentPluginAuthor?
    public var homepage: String?
    public var repository: String?
    public var license: String?
    public var keywords: [String]
    public var derrick: DerrickExtensionPointers?
    public var ignoredUnknownFields: [String]
    public var ignoredExtensionNamespaces: [String]

    public init(
        name: PluginID,
        schema: String = PluginContract.agentPluginSchema,
        version: String? = nil,
        description: String? = nil,
        author: AgentPluginAuthor? = nil,
        homepage: String? = nil,
        repository: String? = nil,
        license: String? = nil,
        keywords: [String] = [],
        derrick: DerrickExtensionPointers? = nil,
        ignoredUnknownFields: [String] = [],
        ignoredExtensionNamespaces: [String] = []
    ) {
        self.schema = schema
        self.name = name
        self.version = version
        self.description = description
        self.author = author
        self.homepage = homepage
        self.repository = repository
        self.license = license
        self.keywords = keywords
        self.derrick = derrick
        self.ignoredUnknownFields = ignoredUnknownFields
        self.ignoredExtensionNamespaces = ignoredExtensionNamespaces
    }

    public static let permittedTopLevelKeys: Set<String> = [
        "$schema", "name", "version", "description", "author",
        "homepage", "repository", "license", "keywords", "extensions",
    ]

    public static func decode(_ data: Data) throws -> AgentPluginManifest {
        let json: PluginJSON
        do {
            json = try JSONDecoder().decode(PluginJSON.self, from: data)
        } catch {
            throw PluginManifestError.invalidJSON
        }
        guard case .object(let object) = json else {
            throw PluginManifestError.notAnObject
        }
        return try decode(object)
    }

    public static func decode(_ object: [String: PluginJSON]) throws -> AgentPluginManifest {
        var ignoredUnknown: [String] = []
        for key in object.keys where !permittedTopLevelKeys.contains(key) {
            ignoredUnknown.append(key)
        }

        guard let schemaJSON = object["$schema"] else {
            throw PluginManifestError.missingSchema
        }
        guard case .string(let schema) = schemaJSON else {
            throw PluginManifestError.invalidFieldType("$schema")
        }
        guard schema == PluginContract.agentPluginSchema else {
            throw PluginManifestError.unsupportedSchema(schema)
        }

        guard let nameJSON = object["name"] else {
            throw PluginManifestError.missingName
        }
        guard case .string(let nameRaw) = nameJSON else {
            throw PluginManifestError.invalidFieldType("name")
        }
        let name = try PluginID(nameRaw)

        let version = try optionalString(object, "version")
        let description = try optionalString(object, "description")
        let homepage = try optionalString(object, "homepage")
        let repository = try optionalString(object, "repository")
        let license = try optionalString(object, "license")
        let keywords = try optionalStringArray(object, "keywords")
        let author = try decodeAuthor(object["author"])

        var derrick: DerrickExtensionPointers?
        var ignoredNamespaces: [String] = []
        if let extensionsJSON = object["extensions"] {
            switch extensionsJSON {
            case .object(let extensions):
                for (namespace, value) in extensions {
                    if namespace == PluginContract.derrickExtensionNamespace {
                        derrick = try DerrickExtensionPointers.decode(value)
                    } else {
                        ignoredNamespaces.append(namespace)
                    }
                }
            default:
                break
            }
        }

        return AgentPluginManifest(
            name: name,
            schema: schema,
            version: version,
            description: description,
            author: author,
            homepage: homepage,
            repository: repository,
            license: license,
            keywords: keywords ?? [],
            derrick: derrick,
            ignoredUnknownFields: ignoredUnknown.sorted(),
            ignoredExtensionNamespaces: ignoredNamespaces.sorted()
        )
    }

    private static func optionalString(_ object: [String: PluginJSON], _ key: String) throws -> String? {
        guard let value = object[key] else { return nil }
        guard case .string(let string) = value else {
            throw PluginManifestError.invalidFieldType(key)
        }
        return string
    }

    private static func optionalStringArray(_ object: [String: PluginJSON], _ key: String) throws -> [String]? {
        guard let value = object[key] else { return nil }
        guard case .array(let items) = value else {
            throw PluginManifestError.invalidFieldType(key)
        }
        return try items.map { item in
            guard case .string(let string) = item else {
                throw PluginManifestError.invalidFieldType(key)
            }
            return string
        }
    }

    private static func decodeAuthor(_ value: PluginJSON?) throws -> AgentPluginAuthor? {
        guard let value else { return nil }
        guard case .object(let object) = value else {
            throw PluginManifestError.invalidAuthor
        }
        let allowed: Set<String> = ["name", "email", "url"]
        guard object.keys.allSatisfy({ allowed.contains($0) }) else {
            throw PluginManifestError.invalidAuthor
        }
        func field(_ key: String) throws -> String? {
            guard let raw = object[key] else { return nil }
            guard case .string(let string) = raw else {
                throw PluginManifestError.invalidAuthor
            }
            return string
        }
        return AgentPluginAuthor(name: try field("name"), email: try field("email"), url: try field("url"))
    }
}

public struct AgentPluginAuthor: Codable, Sendable, Hashable {
    public var name: String?
    public var email: String?
    public var url: String?

    public init(name: String? = nil, email: String? = nil, url: String? = nil) {
        self.name = name
        self.email = email
        self.url = url
    }
}

public struct DerrickExtensionPointers: Sendable, Hashable {
    public var entrypoint: String?
    public var runtime: String?
    public var secrets: [PluginSecretField]
    public var role: PluginRole

    public var isConnector: Bool { role.isConnector }

    public init(
        entrypoint: String? = nil,
        runtime: String? = nil,
        secrets: [PluginSecretField] = [],
        role: PluginRole = .standard
    ) throws {
        if let entrypoint {
            self.entrypoint = try PluginPath.validateRuntimeEntrypoint(entrypoint)
        } else {
            self.entrypoint = nil
        }
        if let runtime {
            self.runtime = try PluginPath.validateRelative(runtime)
        } else {
            self.runtime = nil
        }
        self.secrets = secrets
        self.role = role
    }

    public static func decode(_ json: PluginJSON) throws -> DerrickExtensionPointers {
        guard case .object(let object) = json else {
            throw PluginManifestError.invalidFieldType("extensions.app.derrick")
        }
        func path(_ key: String) throws -> String? {
            guard let value = object[key] else { return nil }
            guard case .string(let string) = value else {
                throw PluginManifestError.invalidFieldType("extensions.app.derrick.\(key)")
            }
            return string
        }
        return try DerrickExtensionPointers(
            entrypoint: try path("entrypoint"),
            runtime: try path("runtime"),
            secrets: try PluginSecretField.decodeList(object["secrets"]),
            role: try decodeRole(object["role"])
        )
    }

    private static func decodeRole(_ json: PluginJSON?) throws -> PluginRole {
        guard let json else { return .standard }
        guard case .string(let raw) = json else {
            throw PluginManifestError.invalidFieldType("extensions.app.derrick.role")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let role = PluginRole(rawValue: trimmed) else {
            throw PluginManifestError.invalidRole(raw)
        }
        return role
    }
}

extension AgentPluginManifest {
    public var isConnector: Bool { derrick?.isConnector == true }

    public static func isConnector(manifestJSON: String) -> Bool {
        guard let data = manifestJSON.data(using: .utf8),
              let manifest = try? decode(data)
        else {
            return false
        }
        return manifest.isConnector
    }
}
