import Foundation
import Structure

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
        try validateSource(draft.guestSource)

        let direct: PluginFactoryExecutionResult
        do {
            direct = try await executor.runGuestSource(
                source: draft.guestSource,
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
            let findingMessages = review.findings.map(\.message)
            let detail = findingMessages.isEmpty
                ? review.summary
                : "\(review.summary) \(findingMessages.joined(separator: " "))"
            await logger("[plugin_factory] review rejected=\(pluginFactoryLogValue(detail))")
            throw PluginFactoryError.reviewRejected(
                summary: review.summary,
                findings: findingMessages
            )
        }

        let artifact: Data
        do {
            artifact = try await executor.packageGuestSource(source: draft.guestSource)
        } catch {
            await logger("[plugin_factory] package failed=\(pluginFactoryLogValue(error.localizedDescription))")
            throw PluginFactoryError.packageFailed(error.localizedDescription)
        }
        await logger("[plugin_factory] package succeeded artifact_bytes=\(artifact.count)")
        guard !artifact.isEmpty else {
            await logger("[plugin_factory] package rejected=empty guest source artifact")
            throw PluginFactoryError.packageFailed("Guest source artifact is empty.")
        }

        let packaged: PluginFactoryExecutionResult
        do {
            packaged = try await executor.runPackagedArtifact(
                artifact,
                input: draft.testInput
            )
        } catch {
            await logger("[plugin_factory] packaged_test failed=\(pluginFactoryLogValue(error.localizedDescription))")
            throw PluginFactoryError.packagedRunFailed(error.localizedDescription)
        }
        await logger(
            "[plugin_factory] packaged_test exit=\(packaged.exitCode) " +
            "stdout_chars=\(packaged.stdout.count) stderr_chars=\(packaged.stderr.count)"
        )
        guard packaged.exitCode == 0 else {
            await logger("[plugin_factory] packaged_test rejected=\(pluginFactoryLogValue(outputSummary(packaged)))")
            throw PluginFactoryError.packagedRunFailed(outputSummary(packaged))
        }
        do {
            try validateOutput(packaged.stdout)
        } catch {
            await logger("[plugin_factory] packaged_output invalid=\(pluginFactoryLogValue(error.localizedDescription))")
            throw PluginFactoryError.invalidPackagedOutput(error.localizedDescription)
        }

        let runtimeJSON = try runtimeJSON(for: manifest)
        var files: [String: Data] = [
            "plugin.json": Data(draft.manifestJSON.utf8),
            "app.derrick/runtime.json": Data(runtimeJSON.utf8),
            "app.derrick/plugin.py": Data(draft.guestSource.utf8),
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
            guestSource: draft.guestSource,
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
                  entrypoint.hasSuffix(".py") else {
                throw PluginFactoryError.invalidManifest(
                    "extensions.app.derrick.entrypoint must point to a Python file."
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
        let findings = GuestPythonSourceValidator.validate(source: source)
        if let first = findings.first {
            throw PluginFactoryError.invalidSource(first)
        }
    }

    private func runtimeJSON(for manifest: AgentPluginManifest) throws -> String {
        guard let entrypoint = manifest.derrick?.entrypoint else {
            throw PluginFactoryError.invalidManifest("A Python entrypoint is required.")
        }
        let object: [String: String] = [
            "language": "python",
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
