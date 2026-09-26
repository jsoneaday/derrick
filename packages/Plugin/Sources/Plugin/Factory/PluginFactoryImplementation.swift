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
                if ModelProviderLimit.matches(error.localizedDescription)
                    || Self.isProviderHTTPFailure(error.localizedDescription) {
                    throw error
                }
                let wrapped = PluginFactoryError.invalidSource(error.localizedDescription)
                lastError = wrapped
                await logger(
                    "[plugin_factory] attempt=\(attempt + 1)/\(configuration.maxBuilderAttempts) " +
                    "failed=\(pluginFactoryLogValue(wrapped.localizedDescription))"
                )
                let lower = error.localizedDescription.lowercased()
                if lower.contains("no api key"), lower.contains("available") {
                    throw error
                }
                guard attempt + 1 < configuration.maxBuilderAttempts else {
                    throw wrapped
                }
                request = PluginFactoryBuilderRequest(
                    userGoal: userGoal,
                    previousDraft: currentDraft,
                    feedback: Self.builderFeedback(from: wrapped, userGoal: userGoal),
                    hostManifest: hostManifest
                )
            }
        }
        throw lastError ?? PluginFactoryError.invalidSource("Factory stopped without a result.")
    }

    /// Model HTTP failures are not a bad Go draft. Retrying them repeats the same refusal.
    private static func isProviderHTTPFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("http 4") || lower.contains("http 5")
            || lower.contains("invalid_request_error")
            || lower.contains("unsupported_value")
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
        case .invalidSource(let message) where message.lowercased().contains("invalid draft json"):
            return """
            The host could not parse your last draft.
            \(message)
            Return exactly one JSON object. go_source and test_input_json are required.
            test_input_json must be a JSON string, not a nested object.
            Do not wrap the object in markdown.
            """
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

        let codeReviewInput = PluginFactoryExecutionResult(
            exitCode: 0,
            stdout: Data("CODE_REVIEW\nTests have not been run. Review the source and the test plan only.".utf8)
        )
        let codeReview: PluginFactoryReview
        do {
            await logger("[plugin_factory] review_started")
            codeReview = try await reviewer.review(draft: draft, directRun: codeReviewInput)
        } catch {
            await logger("[plugin_factory] review failed=\(pluginFactoryLogValue(error.localizedDescription))")
            throw error
        }
        await logger(
            "[plugin_factory] review decision=\(codeReview.decision.rawValue) " +
            "finding_count=\(codeReview.findings.count) summary=\(pluginFactoryLogValue(codeReview.summary))"
        )
        guard codeReview.approved else {
            let findingMessages = codeReview.findings.map(\.message)
            let detail = findingMessages.isEmpty
                ? codeReview.summary
                : "\(codeReview.summary) \(findingMessages.joined(separator: " "))"
            await logger("[plugin_factory] review rejected=\(pluginFactoryLogValue(detail))")
            throw PluginFactoryError.reviewRejected(
                summary: codeReview.summary,
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

        let review: PluginFactoryReview
        if let liveExecutor = executor as? any PluginFactoryLiveAcceptanceExecutor {
            await logger("[plugin_factory] live_acceptance_started")
            let live: PluginFactoryHopTestRun
            do {
                live = try await liveExecutor.runLiveAcceptance(
                    artifact: artifact,
                    testInput: draft.testInput
                )
            } catch {
                await logger("[plugin_factory] live_acceptance failed=\(pluginFactoryLogValue(error.localizedDescription))")
                throw PluginFactoryError.directRunFailed(error.localizedDescription)
            }
            let transcript = live.aggregatedDirectRun
            let ops = PluginFactoryValidationExpectations.messagingOps(fromManifestJSON: draft.manifestJSON)
            let stdout = String(decoding: transcript.stdout, as: UTF8.self)
            if let problem = PluginLiveAcceptance.problem(
                testInput: draft.testInput,
                stdout: stdout,
                stderr: String(decoding: transcript.stderr, as: UTF8.self),
                exitCode: transcript.exitCode,
                messagingOps: ops
            ) {
                await logger("[plugin_factory] live_acceptance failed=\(pluginFactoryLogValue(problem))")
                throw PluginFactoryError.directRunFailed(problem)
            }
            await logger(
                "[plugin_factory] live_acceptance exit=\(transcript.exitCode) stdout_chars=\(transcript.stdout.count)"
            )
            let liveInput = PluginFactoryExecutionResult(
                exitCode: 0,
                stdout: Data("LIVE_TEST\n\(stdout)".utf8),
                stderr: transcript.stderr
            )
            do {
                await logger("[plugin_factory] review_started")
                review = try await reviewer.review(draft: draft, directRun: liveInput)
            } catch {
                await logger("[plugin_factory] review failed=\(pluginFactoryLogValue(error.localizedDescription))")
                throw error
            }
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
        } else {
            review = codeReview
        }

        let guestPath = PluginFactoryRuntime.guestSourcePackagePath(
            runtimeJSON: "",
            manifestJSON: draft.manifestJSON
        )
        guard draft.skillFiles.keys.contains(where: { PluginFactorySkillFile.isSkillMarkdownPath($0) }) else {
            throw PluginFactoryError.missingSkillFiles
        }
        var files: [String: Data] = [
            "plugin.json": Data(draft.manifestJSON.utf8),
            guestPath: Data(draft.guestSource.utf8),
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
            runtimeJSON: "",
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
