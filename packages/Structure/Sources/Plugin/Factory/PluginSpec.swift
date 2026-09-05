import Foundation

/// Immutable, host-owned description of a generated plugin.
public struct PluginSpec: Codable, Sendable, Hashable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var pluginID: String
    public var version: String
    public var purpose: String
    public var parameters: [PluginParameterSpec]
    public var output: PluginOutputSpec
    public var capabilities: [PluginCapability]
    public var limits: PluginResourceLimits
    public var fixtures: [PluginFixture]
    public var assertions: [PluginAssertion]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case pluginID = "plugin_id"
        case version, purpose, parameters, output, capabilities, limits, fixtures, assertions
    }

    public init(
        schemaVersion: Int = PluginSpec.currentSchemaVersion,
        pluginID: String,
        version: String = "1.0.0",
        purpose: String,
        parameters: [PluginParameterSpec] = [],
        output: PluginOutputSpec = PluginOutputSpec(),
        capabilities: [PluginCapability] = [.resultEmit],
        limits: PluginResourceLimits = PluginResourceLimits(),
        fixtures: [PluginFixture] = [],
        assertions: [PluginAssertion] = []
    ) {
        self.schemaVersion = schemaVersion
        self.pluginID = pluginID
        self.version = version
        self.purpose = purpose
        self.parameters = parameters
        self.output = output
        self.capabilities = capabilities
        self.limits = limits
        self.fixtures = fixtures
        self.assertions = assertions
    }

    public func validated() throws -> PluginSpec {
        let problems = validationProblems
        guard problems.isEmpty else {
            throw PluginSpecError.invalid(problems)
        }
        return self
    }

    public var validationProblems: [String] {
        var problems: [String] = []
        if schemaVersion != Self.currentSchemaVersion {
            problems.append("Unsupported PluginSpec schema version \(schemaVersion).")
        }
        if (try? PluginID(pluginID)) == nil {
            problems.append("plugin_id must be a valid plugin id.")
        }
        if purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("purpose must not be empty.")
        }
        var names = Set<String>()
        for parameter in parameters {
            if !names.insert(parameter.name).inserted {
                problems.append("Duplicate parameter: \(parameter.name).")
            }
            problems.append(contentsOf: parameter.validationProblems)
        }
        problems.append(contentsOf: output.validationProblems)
        problems.append(contentsOf: limits.validationProblems)
        if capabilities.isEmpty {
            problems.append("At least one capability is required.")
        }
        if fixtures.isEmpty {
            problems.append("At least one deterministic fixture is required.")
        }
        if assertions.isEmpty {
            problems.append("At least one behavioral assertion is required.")
        }
        let fixtureNames = Set(fixtures.map(\.name))
        for fixture in fixtures {
            problems.append(contentsOf: fixture.validationProblems)
        }
        for assertion in assertions {
            problems.append(contentsOf: assertion.validationProblems)
            if !fixtureNames.contains(assertion.fixtureName) {
                problems.append("Assertion references unknown fixture \(assertion.fixtureName).")
            }
        }
        return problems
    }
}

public enum PluginSpecError: Error, LocalizedError, Equatable, Sendable {
    case invalid([String])

    public var errorDescription: String? {
        switch self {
        case .invalid(let problems):
            return problems.joined(separator: " ")
        }
    }
}

public enum PluginCapability: String, Codable, Sendable, Hashable, CaseIterable {
    case httpFetch = "http_fetch"
    case resultEmit = "result_emit"
    case uiRequest = "ui_request"
    case secretRequest = "secret_request"
    case storage = "storage"
    case scheduling = "scheduling"
}

public enum PluginParameterType: String, Codable, Sendable, Hashable {
    case string
    case number
    case boolean
    case stringList = "string[]"
    case numberList = "number[]"
}

public struct PluginParameterSpec: Codable, Sendable, Hashable {
    public var name: String
    public var type: PluginParameterType
    public var description: String
    public var required: Bool
    public var defaultValue: PluginJSON?
    public var examples: [PluginJSON]

    enum CodingKeys: String, CodingKey {
        case name, type, description, required
        case defaultValue = "default_value"
        case examples
    }

    public init(
        name: String,
        type: PluginParameterType,
        description: String = "",
        required: Bool = false,
        defaultValue: PluginJSON? = nil,
        examples: [PluginJSON] = []
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
        self.defaultValue = defaultValue
        self.examples = examples
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(PluginParameterType.self, forKey: .type)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
        defaultValue = try container.decodeIfPresent(PluginJSON.self, forKey: .defaultValue)
        examples = try container.decodeIfPresent([PluginJSON].self, forKey: .examples) ?? []
    }

    public var validationProblems: [String] {
        var problems: [String] = []
        if name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) == nil {
            problems.append("Invalid parameter name: \(name).")
        }
        if required, defaultValue != nil {
            problems.append("Required parameter \(name) cannot have a default.")
        }
        return problems
    }
}

public struct PluginOutputSpec: Codable, Sendable, Hashable {
    public var title: String
    public var summaryDescription: String
    public var jsonSchema: PluginJSON?
    public var requiredFields: [String]
    public var allowEmpty: Bool

    enum CodingKeys: String, CodingKey {
        case title
        case summaryDescription = "summary_description"
        case jsonSchema = "json_schema"
        case requiredFields = "required_fields"
        case allowEmpty = "allow_empty"
    }

    public init(
        title: String = "Plugin result",
        summaryDescription: String = "A user-readable plugin result.",
        jsonSchema: PluginJSON? = nil,
        requiredFields: [String] = [],
        allowEmpty: Bool = false
    ) {
        self.title = title
        self.summaryDescription = summaryDescription
        self.jsonSchema = jsonSchema
        self.requiredFields = requiredFields
        self.allowEmpty = allowEmpty
    }

    public var validationProblems: [String] {
        var problems: [String] = []
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("output.title must not be empty.")
        }
        if summaryDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("output.summary_description must not be empty.")
        }
        return problems
    }
}

public struct PluginResourceLimits: Codable, Sendable, Hashable {
    public var maxHops: Int
    public var maxHTTPRequests: Int
    public var maxResponseBytes: Int
    public var maxOutputBytes: Int
    public var timeoutSeconds: Int

    enum CodingKeys: String, CodingKey {
        case maxHops = "max_hops"
        case maxHTTPRequests = "max_http_requests"
        case maxResponseBytes = "max_response_bytes"
        case maxOutputBytes = "max_output_bytes"
        case timeoutSeconds = "timeout_seconds"
    }

    public init(
        maxHops: Int = PluginContract.maxHops,
        maxHTTPRequests: Int = PluginContract.defaultHTTPCallsPerInvoke,
        maxResponseBytes: Int = PluginContract.defaultHTTPJSONBytes,
        maxOutputBytes: Int = PluginContract.defaultHTTPJSONBytes,
        timeoutSeconds: Int = PluginContract.defaultTimeoutSeconds
    ) {
        self.maxHops = maxHops
        self.maxHTTPRequests = maxHTTPRequests
        self.maxResponseBytes = maxResponseBytes
        self.maxOutputBytes = maxOutputBytes
        self.timeoutSeconds = timeoutSeconds
    }

    public var validationProblems: [String] {
        [
            maxHops > 0 ? nil : "limits.max_hops must be positive.",
            maxHTTPRequests > 0 ? nil : "limits.max_http_requests must be positive.",
            maxResponseBytes > 0 ? nil : "limits.max_response_bytes must be positive.",
            maxOutputBytes > 0 ? nil : "limits.max_output_bytes must be positive.",
            timeoutSeconds > 0 ? nil : "limits.timeout_seconds must be positive.",
        ].compactMap { $0 }
    }
}

public struct PluginFixture: Codable, Sendable, Hashable {
    public var name: String
    public var event: PluginHopEvent
    public var httpResponses: [HostHTTPResponse]

    enum CodingKeys: String, CodingKey {
        case name, event
        case httpResponses = "http_responses"
    }

    public init(
        name: String,
        event: PluginHopEvent,
        httpResponses: [HostHTTPResponse] = []
    ) {
        self.name = name
        self.event = event
        self.httpResponses = httpResponses
    }

    public var validationProblems: [String] {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ["Fixture name must not be empty."]
            : []
    }
}

public enum PluginAssertionKind: String, Codable, Sendable, Hashable, CaseIterable {
    case emitsResult = "emits_result"
    case outputContains = "output_contains"
    case outputFieldPresent = "output_field_present"
    case outputCountAtMost = "output_count_at_most"
    case requestCount = "request_count"
}

public struct PluginAssertion: Codable, Sendable, Hashable {
    public var fixtureName: String
    public var kind: PluginAssertionKind
    public var path: String?
    public var stringValue: String?
    public var integerValue: Int?

    enum CodingKeys: String, CodingKey {
        case fixtureName = "fixture_name"
        case kind, path
        case stringValue = "string_value"
        case integerValue = "integer_value"
    }

    public init(
        fixtureName: String,
        kind: PluginAssertionKind,
        path: String? = nil,
        stringValue: String? = nil,
        integerValue: Int? = nil
    ) {
        self.fixtureName = fixtureName
        self.kind = kind
        self.path = path
        self.stringValue = stringValue
        self.integerValue = integerValue
    }

    public var validationProblems: [String] {
        fixtureName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ["Assertion fixture_name must not be empty."]
            : []
    }
}
