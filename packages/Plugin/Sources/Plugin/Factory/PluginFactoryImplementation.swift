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
        hostManifest: PluginFactoryManifestInput? = nil,
        builder: any PluginFactoryBuilder,
        executor: any PluginFactoryExecutor,
        reviewer: any PluginFactoryReviewer,
        logger: @escaping PluginFactoryLogger = { _ in }
    ) async throws -> PluginFactoryRelease {
        var request = PluginFactoryBuilderRequest(userGoal: userGoal, hostManifest: hostManifest)
        var lastError: PluginFactoryError?
        var currentDraft: PluginFactoryDraft?

        for attempt in 0..<configuration.maxBuilderAttempts {
            do {
                await logger(
                    "[plugin_factory] attempt=\(attempt + 1)/\(configuration.maxBuilderAttempts) draft_started"
                )
                let builtDraft = try await builder.makeDraft(request)
                var draft = builtDraft.withUserGoal(userGoal)
                if let hostManifest {
                    draft = try draft.replacingManifest(hostManifest)
                }
                currentDraft = draft
                await logger("[plugin_factory] draft_ready")
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
                    feedback: Self.builderFeedback(from: error, userGoal: userGoal),
                    hostManifest: hostManifest
                )
            } catch {
                await logger(
                    "[plugin_factory] attempt=\(attempt + 1)/\(configuration.maxBuilderAttempts) " +
                    "failed=\(pluginFactoryLogValue(error.localizedDescription))"
                )
                throw error
            }
        }
        throw lastError ?? PluginFactoryError.invalidSource("Factory stopped without a result.")
    }

    private static func builderFeedback(from error: PluginFactoryError, userGoal: String) -> String {
        switch error {
        case .draftValidationFailed(let findings):
            var parts = [
                "Deterministic draft validation failed before safety review.",
                "Fix every item below in your next JSON draft response:",
            ]
            parts.append(contentsOf: findings.map { "- \($0)" })
            parts.append(ScriptExecContractPrompts.pluginFactoryBuilderGuide())
            parts.append(ConnectorContractPrompts.builderGuide(forUserGoal: userGoal))
            return parts.joined(separator: "\n")
        case .reviewRejected(let summary, let findings):
            var parts = [
                "Safety review rejected the draft.",
                "Summary: \(summary)",
            ]
            if !findings.isEmpty {
                parts.append("Findings:")
                parts.append(contentsOf: findings.map { "- \($0)" })
            }
            parts.append(ScriptExecContractPrompts.pluginFactoryReviewerGuide())
            parts.append(ConnectorContractPrompts.reviewerGuide(forUserGoal: userGoal))
            return parts.joined(separator: "\n")
        default:
            return error.localizedDescription
        }
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
        try PluginFactoryDraftValidator.validateStructure(draft: draft, manifest: manifest)

        let hopRun: PluginFactoryHopTestRun
        do {
            await logger("[plugin_factory] direct_test_started")
            hopRun = try await PluginFactoryHopTestRunner.run(
                source: draft.guestSource,
                testInput: draft.testInput,
                executor: executor
            )
        } catch {
            await logger("[plugin_factory] direct_test failed=\(pluginFactoryLogValue(error.localizedDescription))")
            throw PluginFactoryError.directRunFailed(error.localizedDescription)
        }
        let direct = hopRun.final
        let reviewRun = hopRun.aggregatedDirectRun
        await logger(
            "[plugin_factory] direct_test exit=\(direct.exitCode) " +
            "stdout_chars=\(reviewRun.stdout.count) stderr_chars=\(direct.stderr.count)"
        )
        guard direct.exitCode == 0 else {
            await logger("[plugin_factory] direct_test rejected=\(pluginFactoryLogValue(outputSummary(direct)))")
            throw PluginFactoryError.directRunFailed(outputSummary(direct))
        }
        do {
            try validateOutput(direct.stdout)
            try PluginFactoryDraftValidator.validateDirectTest(
                draft: draft,
                manifest: manifest,
                hopRun: hopRun
            )
        } catch let error as PluginFactoryError {
            switch error {
            case .draftValidationFailed:
                await logger(
                    "[plugin_factory] draft_validation failed=\(pluginFactoryLogValue(error.localizedDescription))"
                )
                throw error
            default:
                await logger("[plugin_factory] direct_output invalid=\(pluginFactoryLogValue(error.localizedDescription))")
                throw error
            }
        } catch {
            await logger("[plugin_factory] direct_output invalid=\(pluginFactoryLogValue(error.localizedDescription))")
            throw PluginFactoryError.invalidDirectOutput(error.localizedDescription)
        }

        let review: PluginFactoryReview
        do {
            await logger("[plugin_factory] review_started")
            review = try await reviewer.review(draft: draft, directRun: reviewRun)
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
            await logger("[plugin_factory] package_started")
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

        let packagedRun: PluginFactoryHopTestRun
        do {
            await logger("[plugin_factory] packaged_test_started")
            packagedRun = try await PluginFactoryHopTestRunner.run(
                artifact: artifact,
                testInput: draft.testInput,
                executor: executor
            )
        } catch {
            await logger("[plugin_factory] packaged_test failed=\(pluginFactoryLogValue(error.localizedDescription))")
            throw PluginFactoryError.packagedRunFailed(error.localizedDescription)
        }
        let packaged = packagedRun.final
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
            try PluginFactoryDraftValidator.validateDirectTest(
                draft: draft,
                manifest: manifest,
                hopRun: packagedRun
            )
        } catch let error as PluginFactoryError {
            switch error {
            case .draftValidationFailed:
                await logger(
                    "[plugin_factory] packaged_validation failed=\(pluginFactoryLogValue(error.localizedDescription))"
                )
                throw error
            default:
                await logger("[plugin_factory] packaged_output invalid=\(pluginFactoryLogValue(error.localizedDescription))")
                throw error
            }
        } catch {
            await logger("[plugin_factory] packaged_output invalid=\(pluginFactoryLogValue(error.localizedDescription))")
            throw PluginFactoryError.invalidPackagedOutput(error.localizedDescription)
        }

        let runtimeJSON = try runtimeJSON(for: manifest)
        var files: [String: Data] = [
            "plugin.json": Data(draft.manifestJSON.utf8),
            "app.derrick/runtime.json": Data(runtimeJSON.utf8),
            "app.derrick/plugin.go": Data(draft.guestSource.utf8),
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
                  entrypoint.hasSuffix(".go") else {
                throw PluginFactoryError.invalidManifest(
                    "extensions.app.derrick.entrypoint must point to a Go file."
                )
            }
            guard !["create-plugin", "edit-plugin"].contains(manifest.name.rawValue) else {
                throw PluginFactoryError.reservedPluginID(manifest.name.rawValue)
            }
            if manifest.isConnector {
                let secrets = manifest.derrick?.secrets ?? []
                guard !secrets.isEmpty else {
                    throw PluginFactoryError.invalidManifest(
                        "Connector plugins must declare extensions.app.derrick.secrets."
                    )
                }
                guard manifest.derrick?.authScheme != nil else {
                    throw PluginFactoryError.invalidManifest(
                        "Connector plugins must declare extensions.app.derrick.auth_scheme."
                    )
                }
            }
            return manifest
        } catch let error as PluginFactoryError {
            throw error
        } catch {
            throw PluginFactoryError.invalidManifest(error.localizedDescription)
        }
    }

    private func validateSource(_ source: String) throws {
        let findings = GuestGoSourceValidator.validate(source: source)
        if let first = findings.first {
            throw PluginFactoryError.invalidSource(first)
        }
    }

    private func runtimeJSON(for manifest: AgentPluginManifest) throws -> String {
        guard let entrypoint = manifest.derrick?.entrypoint else {
            throw PluginFactoryError.invalidManifest("A Go entrypoint is required.")
        }
        let object: [String: String] = [
            "language": "go",
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
