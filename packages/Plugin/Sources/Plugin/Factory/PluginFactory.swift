import Foundation

public typealias PluginFactoryLogger = @Sendable (String) async -> Void

/// The factory creates Agent Plugin packages whose Derrick entrypoint is Swift.
/// A draft is always a standalone file: the container runs it with `swift file.swift`.
/// A released version is run only from the optimized artifact returned by `swiftc -O`.
public struct PluginFactoryDraft: Sendable, Hashable {
    public let manifestJSON: String
    public let swiftSource: String
    public let testInput: Data
    public let skillFiles: [String: String]
    /// Original request context supplied only to the independent reviewer.
    /// It is not persisted in the released plugin package.
    public let userGoal: String?

    public init(
        manifestJSON: String,
        swiftSource: String,
        testInput: Data = Data("{}".utf8),
        skillFiles: [String: String] = [:],
        userGoal: String? = nil
    ) {
        self.manifestJSON = manifestJSON
        self.swiftSource = swiftSource
        self.testInput = testInput
        self.skillFiles = skillFiles
        self.userGoal = userGoal
    }

    public init(
        manifest: PluginFactoryManifestInput,
        swiftSource: String,
        testInput: Data = Data("{}".utf8),
        skillFiles: [String: String] = [:],
        userGoal: String? = nil
    ) throws {
        self.init(
            manifestJSON: try manifest.encodedJSON(),
            swiftSource: swiftSource,
            testInput: testInput,
            skillFiles: skillFiles,
            userGoal: userGoal
        )
    }

    public func withUserGoal(_ userGoal: String) -> PluginFactoryDraft {
        PluginFactoryDraft(
            manifestJSON: manifestJSON,
            swiftSource: swiftSource,
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

    public init(
        pluginID: String,
        version: String,
        description: String,
        secrets: [PluginSecretField] = []
    ) {
        self.pluginID = pluginID
        self.version = version
        self.description = description
        self.secrets = secrets
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
            "entrypoint": "./app.derrick/plugin.swift",
        ]
        if !secrets.isEmpty {
            derrick["secrets"] = secrets.map(\.jsonObject)
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
}

/// Input to the builder model. Feedback is present only after a bounded,
/// correctable factory failure; the builder never decides approval.
public struct PluginFactoryBuilderRequest: Sendable, Hashable {
    public let userGoal: String
    public let previousDraft: PluginFactoryDraft?
    public let feedback: String?

    public init(
        userGoal: String,
        previousDraft: PluginFactoryDraft? = nil,
        feedback: String? = nil
    ) {
        self.userGoal = userGoal
        self.previousDraft = previousDraft
        self.feedback = feedback
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
    public let swiftSource: String
    public let testInputJSON: String
    public let skillFiles: [PluginFactorySkillFile]
    public let secrets: [PluginSecretField]

    public init(
        pluginID: String,
        version: String,
        description: String,
        swiftSource: String,
        testInputJSON: String = "{}",
        skillFiles: [PluginFactorySkillFile] = [],
        secrets: [PluginSecretField] = []
    ) {
        self.pluginID = pluginID
        self.version = version
        self.description = description
        self.swiftSource = swiftSource
        self.testInputJSON = testInputJSON
        self.skillFiles = skillFiles
        self.secrets = secrets
    }

    enum CodingKeys: String, CodingKey {
        case pluginID = "plugin_id"
        case version, description
        case swiftSource = "swift_source"
        case testInputJSON = "test_input_json"
        case skillFiles = "skill_files"
        case secrets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pluginID = try container.decode(String.self, forKey: .pluginID)
        version = try container.decode(String.self, forKey: .version)
        description = try container.decode(String.self, forKey: .description)
        swiftSource = try container.decode(String.self, forKey: .swiftSource)
        testInputJSON = try container.decode(String.self, forKey: .testInputJSON)
        skillFiles = try container.decodeIfPresent([PluginFactorySkillFile].self, forKey: .skillFiles) ?? []
        secrets = try container.decodeIfPresent([PluginSecretField].self, forKey: .secrets) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pluginID, forKey: .pluginID)
        try container.encode(version, forKey: .version)
        try container.encode(description, forKey: .description)
        try container.encode(swiftSource, forKey: .swiftSource)
        try container.encode(testInputJSON, forKey: .testInputJSON)
        try container.encode(skillFiles, forKey: .skillFiles)
        if !secrets.isEmpty {
            try container.encode(secrets, forKey: .secrets)
        }
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
                secrets: secrets
            ),
            swiftSource: swiftSource,
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

/// The host supplies this adapter. Its production implementation runs these
/// commands inside the restricted Linux Swift Docker container.
public protocol PluginFactoryExecutor: Sendable {
    func runSwiftFile(source: String, input: Data) async throws -> PluginFactoryExecutionResult
    func compileSwiftFile(source: String) async throws -> Data
    func runCompiledArtifact(_ artifact: Data, input: Data) async throws -> PluginFactoryExecutionResult
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
    public let isSystem: Bool

    public var id: String { "\(pluginID)@\(version)" }

    public init(
        pluginID: String,
        version: String,
        contentHash: String,
        reviewSummary: String,
        isSystem: Bool = false
    ) {
        self.pluginID = pluginID
        self.version = version
        self.contentHash = contentHash
        self.reviewSummary = reviewSummary
        self.isSystem = isSystem
    }
}

public struct PluginFactoryRelease: Sendable, Hashable {
    public let pluginID: String
    public let version: String
    public let manifestJSON: String
    public let runtimeJSON: String
    public let swiftSource: String
    public let compiledArtifact: Data
    public let skillFiles: [String: String]
    public let contentHash: PluginContentHash
    public let reviewSummary: String

    public init(
        pluginID: String,
        version: String,
        manifestJSON: String,
        runtimeJSON: String,
        swiftSource: String,
        compiledArtifact: Data,
        skillFiles: [String: String],
        contentHash: PluginContentHash,
        reviewSummary: String
    ) {
        self.pluginID = pluginID
        self.version = version
        self.manifestJSON = manifestJSON
        self.runtimeJSON = runtimeJSON
        self.swiftSource = swiftSource
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
        var files: [String: Data] = [
            "plugin.json": Data(manifestJSON.utf8),
            "app.derrick/runtime.json": Data(runtimeJSON.utf8),
            "app.derrick/plugin.swift": Data(swiftSource.utf8),
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
    case reviewRejected(String)
    case compileFailed(String)
    case compiledRunFailed(String)
    case invalidCompiledOutput(String)

    public var isBuilderCorrectable: Bool {
        switch self {
        case .directRunFailed, .invalidDirectOutput:
            return true
        case .invalidSkillPath, .invalidManifest:
            return true
        case .reviewRejected:
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
        case .invalidSource(let message): return "Invalid Swift plugin source: \(message)"
        case .directRunFailed(let message): return "Swift draft test failed: \(message)"
        case .invalidDirectOutput(let message): return "Swift draft returned invalid plugin output: \(message)"
        case .reviewRejected(let message): return "Plugin review rejected the draft: \(message)"
        case .compileFailed(let message): return "Swift plugin compilation failed: \(message)"
        case .compiledRunFailed(let message): return "Compiled plugin test failed: \(message)"
        case .invalidCompiledOutput(let message): return "Compiled plugin returned invalid output: \(message)"
        }
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

/// Coordinates the builder model and the deterministic factory. Correctable
/// draft, review, and direct-test diagnostics receive one bounded correction
/// cycle within the configured attempt budget.
public struct PluginFactorySession: Sendable {
    public let configuration: PluginFactoryConfiguration

    public init(configuration: PluginFactoryConfiguration = PluginFactoryConfiguration()) {
        self.configuration = configuration
    }

    public func build(
        userGoal: String,
        builder: any PluginFactoryBuilder,
        executor: any PluginFactoryExecutor,
        reviewer: any PluginFactoryReviewer,
        logger: @escaping PluginFactoryLogger = { _ in }
    ) async throws -> PluginFactoryRelease {
        var request = PluginFactoryBuilderRequest(userGoal: userGoal)
        var lastError: PluginFactoryError?
        var currentDraft: PluginFactoryDraft?

        for attempt in 0..<configuration.maxBuilderAttempts {
            do {
                await logger(
                    "[plugin_factory] attempt=\(attempt + 1)/\(configuration.maxBuilderAttempts) draft_started"
                )
                let builtDraft = try await builder.makeDraft(request)
                let draft = builtDraft.withUserGoal(userGoal)
                currentDraft = draft
                return try await PluginFactory().build(
                    draft: draft,
                    executor: executor,
                    reviewer: reviewer,
                    logger: logger
                )
            } catch let error as PluginFactoryError {
                lastError = error
                await logger(
                    "[plugin_factory] attempt=\(attempt + 1)/\(configuration.maxBuilderAttempts) " +
                    "failed=\(pluginFactoryLogValue(error.localizedDescription))"
                )
                guard error.isBuilderCorrectable,
                      attempt + 1 < configuration.maxBuilderAttempts else {
                    throw error
                }
                request = PluginFactoryBuilderRequest(
                    userGoal: userGoal,
                    previousDraft: currentDraft,
                    feedback: error.localizedDescription
                )
            }
        }
        throw lastError ?? PluginFactoryError.invalidSource("Factory stopped without a result.")
    }
}

/// Review → compile → verify is one operation. Callers must persist only the
/// returned release; draft source is never an approved runtime artifact.
public struct PluginFactory: Sendable {
    public init() {}

    public func build(
        draft: PluginFactoryDraft,
        executor: any PluginFactoryExecutor,
        reviewer: any PluginFactoryReviewer,
        logger: @escaping PluginFactoryLogger = { _ in }
    ) async throws -> PluginFactoryRelease {
        let manifest = try validatedManifest(from: draft.manifestJSON)
        try validateSource(draft.swiftSource)

        let direct: PluginFactoryExecutionResult
        do {
            direct = try await executor.runSwiftFile(
                source: draft.swiftSource,
                input: draft.testInput
            )
        } catch {
            await logger("[plugin_factory] direct_test failed=\(pluginFactoryLogValue(error.localizedDescription))")
            throw PluginFactoryError.directRunFailed(error.localizedDescription)
        }
        await logger(
            "[plugin_factory] direct_test exit=\(direct.exitCode) " +
            "stdout_chars=\(direct.stdout.count) stderr_chars=\(direct.stderr.count)"
        )
        guard direct.exitCode == 0 else {
            await logger("[plugin_factory] direct_test rejected=\(pluginFactoryLogValue(outputSummary(direct)))")
            throw PluginFactoryError.directRunFailed(outputSummary(direct))
        }
        do {
            try validateOutput(direct.stdout)
        } catch {
            await logger("[plugin_factory] direct_output invalid=\(pluginFactoryLogValue(error.localizedDescription))")
            throw PluginFactoryError.invalidDirectOutput(error.localizedDescription)
        }

        let review: PluginFactoryReview
        do {
            review = try await reviewer.review(draft: draft, directRun: direct)
        } catch {
            await logger("[plugin_factory] review failed=\(pluginFactoryLogValue(error.localizedDescription))")
            throw error
        }
        await logger(
            "[plugin_factory] review decision=\(review.decision.rawValue) " +
            "finding_count=\(review.findings.count) summary=\(pluginFactoryLogValue(review.summary))"
        )
        guard review.approved else {
            let findings = review.findings
                .map { "\($0.severity.rawValue): \($0.message)" }
                .joined(separator: " ")
            let detail = findings.isEmpty
                ? review.summary
                : "\(review.summary) \(findings)"
            await logger("[plugin_factory] review rejected=\(pluginFactoryLogValue(detail))")
            throw PluginFactoryError.reviewRejected(detail)
        }

        let artifact: Data
        do {
            artifact = try await executor.compileSwiftFile(source: draft.swiftSource)
        } catch {
            await logger("[plugin_factory] compile failed=\(pluginFactoryLogValue(error.localizedDescription))")
            throw PluginFactoryError.compileFailed(error.localizedDescription)
        }
        await logger("[plugin_factory] compile succeeded artifact_bytes=\(artifact.count)")
        guard !artifact.isEmpty else {
            await logger("[plugin_factory] compile rejected=swiftc returned an empty artifact")
            throw PluginFactoryError.compileFailed("swiftc returned an empty artifact.")
        }

        let compiled: PluginFactoryExecutionResult
        do {
            compiled = try await executor.runCompiledArtifact(
                artifact,
                input: draft.testInput
            )
        } catch {
            await logger("[plugin_factory] compiled_test failed=\(pluginFactoryLogValue(error.localizedDescription))")
            throw PluginFactoryError.compiledRunFailed(error.localizedDescription)
        }
        await logger(
            "[plugin_factory] compiled_test exit=\(compiled.exitCode) " +
            "stdout_chars=\(compiled.stdout.count) stderr_chars=\(compiled.stderr.count)"
        )
        guard compiled.exitCode == 0 else {
            await logger("[plugin_factory] compiled_test rejected=\(pluginFactoryLogValue(outputSummary(compiled)))")
            throw PluginFactoryError.compiledRunFailed(outputSummary(compiled))
        }
        do {
            try validateOutput(compiled.stdout)
        } catch {
            await logger("[plugin_factory] compiled_output invalid=\(pluginFactoryLogValue(error.localizedDescription))")
            throw PluginFactoryError.invalidCompiledOutput(error.localizedDescription)
        }

        let runtimeJSON = try runtimeJSON(for: manifest)
        var files: [String: Data] = [
            "plugin.json": Data(draft.manifestJSON.utf8),
            "app.derrick/runtime.json": Data(runtimeJSON.utf8),
            "app.derrick/plugin.swift": Data(draft.swiftSource.utf8),
            "app.derrick/plugin": artifact,
        ]
        for (path, body) in draft.skillFiles {
            guard PluginFactorySkillFile.isValidPath(path) else {
                throw PluginFactoryError.invalidSkillPath(path)
            }
            files[path] = Data(body.utf8)
        }

        let version = manifest.version ?? "0.1.0"
        return PluginFactoryRelease(
            pluginID: manifest.name.rawValue,
            version: version,
            manifestJSON: draft.manifestJSON,
            runtimeJSON: runtimeJSON,
            swiftSource: draft.swiftSource,
            compiledArtifact: artifact,
            skillFiles: draft.skillFiles,
            contentHash: PluginContentHash.hash(files: files),
            reviewSummary: review.summary
        )
    }

    private func validatedManifest(from json: String) throws -> AgentPluginManifest {
        guard let data = json.data(using: .utf8) else {
            throw PluginFactoryError.invalidManifest("Manifest is not UTF-8.")
        }
        do {
            let manifest = try AgentPluginManifest.decode(data)
            guard let entrypoint = manifest.derrick?.entrypoint,
                  entrypoint.hasSuffix(".swift") else {
                throw PluginFactoryError.invalidManifest(
                    "extensions.app.derrick.entrypoint must point to a Swift file."
                )
            }
            guard !["create-plugin", "edit-plugin"].contains(manifest.name.rawValue) else {
                throw PluginFactoryError.reservedPluginID(manifest.name.rawValue)
            }
            return manifest
        } catch let error as PluginFactoryError {
            throw error
        } catch {
            throw PluginFactoryError.invalidManifest(error.localizedDescription)
        }
    }

    private func validateSource(_ source: String) throws {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PluginFactoryError.invalidSource("Source is empty.")
        }
        // Generated code must not escape the Docker runner or replace host policy.
        let forbidden = ["Process(", "FileHandle.standardError", "URLSession", "Darwin."]
        if let token = forbidden.first(where: { source.contains($0) }) {
            throw PluginFactoryError.invalidSource("Forbidden host escape API: \(token)")
        }
    }

    private func runtimeJSON(for manifest: AgentPluginManifest) throws -> String {
        guard let entrypoint = manifest.derrick?.entrypoint else {
            throw PluginFactoryError.invalidManifest("A Swift entrypoint is required.")
        }
        let object: [String: String] = [
            "language": "swift",
            "entrypoint": entrypoint,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func validateOutput(_ data: Data) throws {
        _ = try PluginEnvelopeList.decode(data)
    }

    private func outputSummary(_ result: PluginFactoryExecutionResult) -> String {
        let stdout = String(decoding: result.stdout, as: UTF8.self)
        let stderr = String(decoding: result.stderr, as: UTF8.self)
        let combined = [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return combined.isEmpty ? "exit \(result.exitCode) with no output." : combined
    }

}

private func pluginFactoryLogValue(_ value: String) -> String {
    let singleLine = value
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
    return String(singleLine.prefix(500))
}
