import Foundation

public typealias PluginFactoryLogger = @Sendable (String) async -> Void

/// The factory creates Agent Plugin packages whose Derrick entrypoint is Go.
/// A draft is compiled to a Linux binary and run as `/tmp/guest` in the worker image.
/// A released version stores the compiled binary as the packaged artifact.
public struct PluginFactoryDraft: Sendable, Hashable {
    public let manifestJSON: String
    public let guestSource: String
    public let testInput: Data
    public let skillFiles: [String: String]
    /// Original request context supplied only to the independent reviewer.
    /// It is not persisted in the released plugin package.
    public let userGoal: String?

    public init(
        manifestJSON: String,
        guestSource: String,
        testInput: Data = Data(#"{"kind":"manual"}"#.utf8),
        skillFiles: [String: String] = [:],
        userGoal: String? = nil
    ) {
        self.manifestJSON = manifestJSON
        self.guestSource = guestSource
        self.testInput = testInput
        self.skillFiles = skillFiles
        self.userGoal = userGoal
    }

    public init(
        manifest: PluginFactoryManifestInput,
        guestSource: String,
        testInput: Data = Data(#"{"kind":"manual"}"#.utf8),
        skillFiles: [String: String] = [:],
        userGoal: String? = nil
    ) throws {
        self.init(
            manifestJSON: try manifest.encodedJSON(),
            guestSource: guestSource,
            testInput: testInput,
            skillFiles: skillFiles,
            userGoal: userGoal
        )
    }

    public func withUserGoal(_ userGoal: String) -> PluginFactoryDraft {
        PluginFactoryDraft(
            manifestJSON: manifestJSON,
            guestSource: guestSource,
            testInput: testInput,
            skillFiles: skillFiles,
            userGoal: userGoal
        )
    }

    public func replacingManifest(_ manifest: PluginFactoryManifestInput) throws -> PluginFactoryDraft {
        PluginFactoryDraft(
            manifestJSON: try manifest.encodedJSON(),
            guestSource: guestSource,
            testInput: testInput,
            skillFiles: skillFiles,
            userGoal: userGoal
        )
    }
}

/// Builder-owned product facts. The factory owns the Agent Plugin schema,
/// Derrick entrypoint, and all required standard fields.
public struct PluginFactoryManifestInput: Sendable, Hashable {
    public let pluginID: String
    public let version: String
    public let description: String
    public let secrets: [PluginSecretField]
    public let role: PluginRole
    public let messagingOps: [String]
    public let authScheme: ConnectorAuthScheme?
    public let permissions: [String]

    public init(
        pluginID: String,
        version: String,
        description: String,
        secrets: [PluginSecretField] = [],
        role: PluginRole = .standard,
        messagingOps: [String] = [],
        authScheme: ConnectorAuthScheme? = nil,
        permissions: [String] = []
    ) {
        self.pluginID = pluginID
        self.version = version
        self.description = description
        self.role = role
        self.messagingOps = messagingOps
        self.permissions = permissions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.secrets = Self.normalizedSecrets(pluginID: pluginID, secrets: secrets, role: role)
        self.authScheme = DerrickExtensionPointers.resolvedAuthScheme(
            declared: authScheme,
            role: role,
            secrets: self.secrets
        )
    }

    public static func connector(
        pluginID: String,
        description: String,
        auth: ConnectorAuthDiscovery,
        version: String = "1.0.0",
        messagingOps: [String] = PluginFactoryCreateInput.ConnectorScope.fullSync.requiredMessagingOps
    ) -> PluginFactoryManifestInput {
        PluginFactoryManifestInput(
            pluginID: pluginID,
            version: version,
            description: description,
            secrets: auth.secrets,
            role: .connector,
            messagingOps: messagingOps,
            authScheme: auth.authScheme,
            permissions: auth.permissions
        )
    }

    /// Slack connectors always declare `bot_token` so the host can prompt or read `.env`.
    private static func normalizedSecrets(
        pluginID: String,
        secrets: [PluginSecretField],
        role: PluginRole
    ) -> [PluginSecretField] {
        if !secrets.isEmpty { return secrets }
        guard role.isConnector else { return secrets }
        return PluginSecretField.resolvedFields(pluginID: pluginID, declared: secrets)
    }

    public func encodedJSON() throws -> String {
        let normalizedID: PluginID
        do {
            normalizedID = try PluginID.normalized(pluginID)
        } catch {
            throw PluginFactoryError.invalidManifest(
                "Invalid plugin id '\(pluginID)'. Use lowercase letters, numbers, hyphens, and dots (for example slack-connection). Underscores are not allowed."
            )
        }
        guard !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginFactoryError.invalidManifest("Version is required.")
        }
        var derrick: [String: Any] = [
            "entrypoint": "./app.derrick/plugin.go",
        ]
        if !secrets.isEmpty {
            derrick["secrets"] = secrets.map(\.jsonObject)
        }
        if role == .connector {
            derrick["role"] = PluginRole.connector.rawValue
            if !messagingOps.isEmpty {
                derrick["messaging_ops"] = messagingOps
            }
            if let authScheme {
                derrick["auth_scheme"] = authScheme.rawValue
            }
            if !permissions.isEmpty {
                derrick["permissions"] = permissions
            }
        }
        let object: [String: Any] = [
            "$schema": PluginContract.agentPluginSchema,
            "name": normalizedID.rawValue,
            "version": version,
            "description": description,
            "extensions": [
                PluginContract.derrickExtensionNamespace: derrick,
            ],
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw PluginFactoryError.invalidManifest("Could not encode the canonical manifest.")
        }
    }

    public static func fromEncodedJSON(_ json: String) throws -> PluginFactoryManifestInput {
        guard let data = json.data(using: .utf8) else {
            throw PluginFactoryError.invalidManifest("Host manifest is not UTF-8.")
        }
        let manifest = try AgentPluginManifest.decode(data)
        return PluginFactoryManifestInput(
            pluginID: manifest.name.rawValue,
            version: manifest.version ?? "1.0.0",
            description: manifest.description ?? "",
            secrets: manifest.derrick?.secrets ?? [],
            role: manifest.derrick?.role ?? .standard,
            messagingOps: manifest.derrick?.messagingOps ?? [],
            authScheme: manifest.derrick?.authScheme,
            permissions: manifest.derrick?.permissions ?? []
        )
    }
}

/// Input to the builder model. Feedback is present only after a bounded,
/// correctable factory failure; the builder never decides approval.
public struct PluginFactoryBuilderRequest: Sendable, Hashable {
    public let userGoal: String
    public let previousDraft: PluginFactoryDraft?
    public let feedback: String?
    /// When set, the host writes `plugin.json`. The builder only supplies Go source and tests.
    public let hostManifest: PluginFactoryManifestInput?

    public init(
        userGoal: String,
        previousDraft: PluginFactoryDraft? = nil,
        feedback: String? = nil,
        hostManifest: PluginFactoryManifestInput? = nil
    ) {
        self.userGoal = userGoal
        self.previousDraft = previousDraft
        self.feedback = feedback
        self.hostManifest = hostManifest
    }
}

/// The helper model translates the user goal into a complete Agent Plugin
/// draft. It must return code, not prose, and has no release authority.
public protocol PluginFactoryBuilder: Sendable {
    func makeDraft(_ request: PluginFactoryBuilderRequest) async throws -> PluginFactoryDraft
}

public struct PluginFactorySkillFile: Codable, Sendable, Hashable {
    public let path: String
    public let body: String

    public init(path: String, body: String) {
        self.path = path
        self.body = body
    }

    public static func isValidPath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0] == "skills",
              components[2] == "SKILL.md"
        else {
            return false
        }
        return components[1].range(
            of: #"^[A-Za-z0-9][A-Za-z0-9_-]*$"#,
            options: .regularExpression
        ) != nil
    }
}

/// Exact structured response returned by the builder model. The host creates
/// `plugin.json`; the model supplies only these product-specific values.
public struct PluginFactoryBuilderResponse: Codable, Sendable, Hashable {
    public let pluginID: String
    public let version: String
    public let description: String
    public let guestSource: String
    public let testInputJSON: String
    public let skillFiles: [PluginFactorySkillFile]
    public let secrets: [PluginSecretField]
    public let role: PluginRole
    public let messagingOps: [String]

    public init(
        pluginID: String,
        version: String,
        description: String,
        guestSource: String,
        testInputJSON: String = #"{"kind":"manual"}"#,
        skillFiles: [PluginFactorySkillFile] = [],
        secrets: [PluginSecretField] = [],
        role: PluginRole = .standard,
        messagingOps: [String] = []
    ) {
        self.pluginID = pluginID
        self.version = version
        self.description = description
        self.guestSource = guestSource
        self.testInputJSON = testInputJSON
        self.skillFiles = skillFiles
        self.secrets = secrets
        self.role = role
        self.messagingOps = messagingOps
    }

    enum CodingKeys: String, CodingKey {
        case pluginID = "plugin_id"
        case version, description
        case guestSource = "go_source"
        case legacySwiftSource = "swift_source"
        case testInputJSON = "test_input_json"
        case skillFiles = "skill_files"
        case secrets
        case role
        case messagingOps = "messaging_ops"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pluginID = try container.decodeIfPresent(String.self, forKey: .pluginID)
            ?? "plugin"
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "1.0.0"
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        guestSource = try {
            if let go = try container.decodeIfPresent(String.self, forKey: .guestSource), !go.isEmpty {
                return go
            }
            if let legacy = try container.decodeIfPresent(String.self, forKey: .legacySwiftSource), !legacy.isEmpty {
                return legacy
            }
            throw DecodingError.keyNotFound(
                CodingKeys.guestSource,
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "go_source is required."
                )
            )
        }()
        testInputJSON = try container.decode(String.self, forKey: .testInputJSON)
        skillFiles = try container.decodeIfPresent([PluginFactorySkillFile].self, forKey: .skillFiles) ?? []
        secrets = try container.decodeIfPresent([PluginSecretField].self, forKey: .secrets) ?? []
        role = try container.decodeIfPresent(PluginRole.self, forKey: .role) ?? .standard
        messagingOps = try container.decodeIfPresent([String].self, forKey: .messagingOps) ?? []
    }

    /// Extracts one draft JSON object from a model reply (markdown fences allowed).
    public static func draft(fromModelText text: String) throws -> PluginFactoryDraft {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText: String
        if normalized.first == "{", normalized.last == "}" {
            jsonText = normalized
        } else if let start = normalized.firstIndex(of: "{"),
                  let end = normalized.lastIndex(of: "}") {
            jsonText = String(normalized[start...end])
        } else {
            throw PluginFactoryError.invalidSource(
                "The plugin builder returned invalid draft JSON (no JSON object)."
            )
        }
        guard let data = jsonText.data(using: .utf8) else {
            throw PluginFactoryError.invalidSource(
                "The plugin builder returned invalid draft JSON."
            )
        }
        do {
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw PluginFactoryError.invalidSource(
                    "The plugin builder returned invalid draft JSON (expected an object)."
                )
            }
            if object["plugin_id"] == nil { object["plugin_id"] = "plugin" }
            if object["version"] == nil { object["version"] = "1.0.0" }
            if object["description"] == nil { object["description"] = "" }
            if object["skill_files"] == nil { object["skill_files"] = [] }
            if let nested = object["test_input_json"], !(nested is String) {
                let nestedData = try JSONSerialization.data(withJSONObject: nested)
                object["test_input_json"] = String(decoding: nestedData, as: UTF8.self)
            }
            let coerced = try JSONSerialization.data(withJSONObject: object)
            return try JSONDecoder().decode(Self.self, from: coerced).draft()
        } catch let error as PluginFactoryError {
            throw error
        } catch {
            throw PluginFactoryError.invalidSource(
                Self.draftJSONFailureMessage(text: jsonText, error: error)
            )
        }
    }

    public static func draftJSONFailureMessage(text: String, error: Error) -> String {
        let reason = describeJSONError(error)
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = String(collapsed.prefix(180))
        let suffix: String
        if collapsed.count > 260 {
            suffix = String(collapsed.suffix(80))
        } else {
            suffix = ""
        }
        var lines = [
            "The plugin builder returned invalid draft JSON.",
            "Reason: \(reason)",
            "Reply length: \(text.count) characters. Ends with closing brace: \(text.trimmingCharacters(in: .whitespacesAndNewlines).last == "}" ? "yes" : "no").",
            "Reply starts with: \(prefix)",
        ]
        if !suffix.isEmpty {
            lines.append("Reply ends with: \(suffix)")
        }
        return lines.joined(separator: " ")
    }

    private static func describeJSONError(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case .keyNotFound(let key, let context):
                let path = (context.codingPath.map(\.stringValue) + [key.stringValue])
                    .filter { !$0.isEmpty }
                    .joined(separator: ".")
                return "missing field \(path)"
            case .typeMismatch(let type, let context):
                let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                return "field \(path.isEmpty ? "(root)" : path) had the wrong type (expected \(type))"
            case .valueNotFound(let type, let context):
                let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                return "field \(path.isEmpty ? "(root)" : path) was null (expected \(type))"
            case .dataCorrupted(let context):
                let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                if path.isEmpty {
                    return context.debugDescription
                }
                return "\(path): \(context.debugDescription)"
            @unknown default:
                break
            }
        }
        let text = error.localizedDescription
        if text.lowercased().contains("end of") || text.lowercased().contains("unterminated") {
            return "JSON was truncated or incomplete"
        }
        return text
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pluginID, forKey: .pluginID)
        try container.encode(version, forKey: .version)
        try container.encode(description, forKey: .description)
        try container.encode(guestSource, forKey: .guestSource)
        try container.encode(testInputJSON, forKey: .testInputJSON)
        try container.encode(skillFiles, forKey: .skillFiles)
        if !secrets.isEmpty {
            try container.encode(secrets, forKey: .secrets)
        }
        if role != .standard {
            try container.encode(role, forKey: .role)
        }
        if !messagingOps.isEmpty {
            try container.encode(messagingOps, forKey: .messagingOps)
        }
    }

    private func resolvedMessagingOps() -> [String] {
        if !messagingOps.isEmpty { return messagingOps }
        return role == .connector
            ? PluginFactoryCreateInput.ConnectorScope.fullSync.requiredMessagingOps
            : []
    }

    public func draft() throws -> PluginFactoryDraft {
        guard let input = testInputJSON.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: input)) != nil else {
            throw PluginFactoryError.invalidSource("test_input_json must be valid JSON.")
        }
        var files: [String: String] = [:]
        for skill in skillFiles {
            guard PluginFactorySkillFile.isValidPath(skill.path) else {
                throw PluginFactoryError.invalidSkillPath(skill.path)
            }
            guard files[skill.path] == nil else {
                throw PluginFactoryError.invalidManifest("Duplicate skill path \(skill.path).")
            }
            files[skill.path] = skill.body
        }
        return try PluginFactoryDraft(
            manifest: PluginFactoryManifestInput(
                pluginID: pluginID,
                version: version,
                description: description,
                secrets: secrets,
                role: role,
                messagingOps: resolvedMessagingOps()
            ),
            guestSource: guestSource,
            testInput: input,
            skillFiles: files
        )
    }
}

public struct PluginFactoryExecutionResult: Sendable, Hashable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// The host supplies this adapter. Its production implementation compiles and
/// runs guests inside the pinned Go worker Docker container.
public protocol PluginFactoryExecutor: Sendable {
    func runGuestSource(source: String, input: Data) async throws -> PluginFactoryExecutionResult
    func packageGuestSource(source: String) async throws -> Data
    func runPackagedArtifact(_ artifact: Data, input: Data) async throws -> PluginFactoryExecutionResult
}

/// Optional compile-once hop replay for factory direct tests.
public protocol PluginFactoryCompiledGuestExecutor: PluginFactoryExecutor {
    func runGuestSourceHops(source: String, testInput: Data) async throws -> PluginFactoryHopTestRun
}

public enum PluginReviewDecision: String, Sendable, Hashable {
    case approved
    case rejected
}

public enum PluginReviewSeverity: String, Sendable, Hashable {
    case info
    case warning
    case blocking
}

public enum PluginReviewCategory: String, Sendable, Hashable {
    case alignment
    case safety
    case correctness
    case privacy
    case supplyChain
}

public struct PluginReviewFinding: Sendable, Hashable {
    public let severity: PluginReviewSeverity
    public let category: PluginReviewCategory
    public let message: String

    public init(
        severity: PluginReviewSeverity,
        category: PluginReviewCategory,
        message: String
    ) {
        self.severity = severity
        self.category = category
        self.message = message
    }
}

public struct PluginFactoryReview: Sendable, Hashable {
    public let decision: PluginReviewDecision
    public let findings: [PluginReviewFinding]
    public let summary: String

    public var approved: Bool { decision == .approved }

    public init(
        decision: PluginReviewDecision,
        findings: [PluginReviewFinding] = [],
        summary: String
    ) {
        self.decision = decision
        self.findings = findings
        self.summary = summary
    }

    public init(approved: Bool, summary: String) {
        self.init(
            decision: approved ? .approved : .rejected,
            summary: summary
        )
    }
}

/// Reviewer input is the exact source that will be compiled after approval.
public protocol PluginFactoryReviewer: Sendable {
    func review(
        draft: PluginFactoryDraft,
        directRun: PluginFactoryExecutionResult
    ) async throws -> PluginFactoryReview
}

public struct PluginFactoryReleaseSummary: Identifiable, Sendable, Hashable {
    public let pluginID: String
    public let version: String
    public let contentHash: String
    public let reviewSummary: String

    public var id: String { "\(pluginID)@\(version)" }

    public init(
        pluginID: String,
        version: String,
        contentHash: String,
        reviewSummary: String
    ) {
        self.pluginID = pluginID
        self.version = version
        self.contentHash = contentHash
        self.reviewSummary = reviewSummary
    }
}

public struct PluginFactoryRelease: Sendable, Hashable {
    public let pluginID: String
    public let version: String
    public let manifestJSON: String
    public let runtimeJSON: String
    public let guestSource: String
    public let compiledArtifact: Data
    public let skillFiles: [String: String]
    public let contentHash: PluginContentHash
    public let reviewSummary: String

    public init(
        pluginID: String,
        version: String,
        manifestJSON: String,
        runtimeJSON: String,
        guestSource: String,
        compiledArtifact: Data,
        skillFiles: [String: String],
        contentHash: PluginContentHash,
        reviewSummary: String
    ) {
        self.pluginID = pluginID
        self.version = version
        self.manifestJSON = manifestJSON
        self.runtimeJSON = runtimeJSON
        self.guestSource = guestSource
        self.compiledArtifact = compiledArtifact
        self.skillFiles = skillFiles
        self.contentHash = contentHash
        self.reviewSummary = reviewSummary
    }

    /// Recompute the digest immediately before execution. A release is usable
    /// only when its manifest, source, skills, runtime metadata, and binary
    /// still match the digest captured at promotion.
    public func verifyIntegrity() -> Bool {
        Self.verifyIntegrity(files: packageFiles(), expected: contentHash)
    }

    /// Verifies files read back from storage before a release is executed.
    public static func verifyIntegrity(
        files: [String: Data],
        expected: PluginContentHash
    ) -> Bool {
        PluginContentHash.hash(files: files) == expected
    }

    public func packageFiles() -> [String: Data] {
        let guestPath = PluginFactoryRuntime.guestSourcePackagePath(
            runtimeJSON: runtimeJSON,
            manifestJSON: manifestJSON
        )
        var files: [String: Data] = [
            "plugin.json": Data(manifestJSON.utf8),
            "app.derrick/runtime.json": Data(runtimeJSON.utf8),
            guestPath: Data(guestSource.utf8),
            "app.derrick/plugin": compiledArtifact,
        ]
        for (path, body) in skillFiles {
            files[path] = Data(body.utf8)
        }
        return files
    }
}

public enum PluginFactoryError: Error, LocalizedError, Equatable, Sendable {
    case invalidManifest(String)
    case invalidSkillPath(String)
    case reservedPluginID(String)
    case invalidSource(String)
    case directRunFailed(String)
    case invalidDirectOutput(String)
    case reviewRejected(summary: String, findings: [String])
    case packageFailed(String)
    case packagedRunFailed(String)
    case invalidPackagedOutput(String)
    case draftValidationFailed(findings: [String])

    public var isBuilderCorrectable: Bool {
        switch self {
        case .directRunFailed, .invalidDirectOutput:
            return true
        case .invalidSkillPath, .invalidManifest, .invalidSource:
            return true
        case .reviewRejected, .draftValidationFailed:
            return true
        default:
            return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let message): return "Invalid Agent Plugin manifest: \(message)"
        case .invalidSkillPath(let path):
            return "Invalid skill path '\(path)'. Skill path must be skills/<name>/SKILL.md."
        case .reservedPluginID(let id): return "The plugin id '\(id)' is reserved by Derrick."
        case .invalidSource(let message): return "Invalid Go guest source: \(message)"
        case .directRunFailed(let message): return "Go draft test failed: \(message)"
        case .invalidDirectOutput(let message): return "Go draft returned invalid plugin output: \(message)"
        case .reviewRejected(let summary, let findings):
            let detail = findings.isEmpty
                ? summary
                : "\(summary) \(findings.joined(separator: " "))"
            return "Plugin review rejected the draft: \(detail)"
        case .packageFailed(let message): return "Go plugin packaging failed: \(message)"
        case .packagedRunFailed(let message): return "Packaged plugin test failed: \(message)"
        case .invalidPackagedOutput(let message): return "Packaged plugin returned invalid output: \(message)"
        case .draftValidationFailed(let findings):
            let detail = findings.joined(separator: " ")
            return findings.count == 1
                ? "Draft validation failed: \(detail)"
                : "Draft validation failed: \(detail)"
        }
    }

    public var draftValidationFindings: [String]? {
        if case .draftValidationFailed(let findings) = self { return findings }
        return nil
    }
}

public struct PluginFactoryConfiguration: Sendable, Hashable {
    /// A correctable factory failure may be shown to the builder within this
    /// total attempt budget, including the initial draft.
    public let maxBuilderAttempts: Int

    public init(maxBuilderAttempts: Int = 3) {
        self.maxBuilderAttempts = min(max(maxBuilderAttempts, 1), 3)
    }
}
