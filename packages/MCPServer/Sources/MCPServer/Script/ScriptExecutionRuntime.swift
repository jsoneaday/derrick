import Foundation
import MCP
import Plugin
import ServiceContracts

public protocol PluginHopHandler: Sendable {
    func handleUIPresent(payload: [String: PluginJSON]) async -> PluginHopEvent?
    func handleSecretRequest(payload: [String: PluginJSON]) async -> PluginHopEvent?
}

/// Runs standalone Swift source and dispatches host-owned capability hops.
public enum ScriptExecutionRuntime {
    public static func run(
        arguments: [String: Value],
        stdinExecutor: @escaping @Sendable ([String], Data, Int) async throws -> DockerCLIResult,
        reviewer: (any ScriptReviewer)?,
        logger: @escaping @Sendable (String) -> Void,
        reviewRequired: Bool = true,
        initialEvent: PluginHopEvent = PluginHopEvent(kind: .script),
        hopHandler: (any PluginHopHandler)? = nil
    ) async throws -> String {
        let started = Date()
        let parsed = try parse(arguments)
        logger("[script_exec] Swift source chars=\(parsed.script.count)")

        let staticStarted = Date()
        let staticFindings = SwiftScriptVerifier.validate(
            source: parsed.script,
            dependencies: parsed.dependencies
        )
        let staticValidateMS = ScriptPhaseTiming.elapsedMS(from: staticStarted)
        if !staticFindings.isEmpty {
            return finish(blocked(
                findings: staticFindings,
                stage: .staticValidation,
                started: started,
                parsed: parsed
            ), logger: logger)
        }

        var reviewerAssessment: ScriptReviewAssessment?
        var reviewerTiming = ScriptReviewerTiming()
        if reviewRequired {
            guard let reviewer else {
                return finish(blocked(
                    findings: ["script_exec requires configured reviewer"],
                    stage: .llmReview,
                    started: started,
                    parsed: parsed
                ), logger: logger)
            }
            let reviewArgs = ScriptExecutionArguments(
                mode: .readonly,
                description: parsed.description,
                reason: parsed.reason,
                script: parsed.script,
                userPrompt: parsed.userPrompt,
                expectedEffects: [],
                dependencies: parsed.dependencies,
                timeoutSeconds: parsed.timeoutSeconds,
                allowNetwork: true
            )
            let extraStatic = ScriptExecutionVerifier.validate(reviewArgs)
            if !extraStatic.isEmpty {
                return finish(blocked(
                    findings: extraStatic,
                    stage: .staticValidation,
                    started: started,
                    parsed: parsed
                ), logger: logger)
            }
            do {
                let outcome = try await reviewer.review(reviewArgs)
                reviewerAssessment = outcome.assessment
                reviewerTiming = outcome.timing
                logger("[script_exec] reviewer: \(outcome.assessment.summary)")
                let action = outcome.assessment.suggestedAction
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if outcome.assessment.alignedWithRequest == false
                    || action == "deny"
                    || action == "confirm" {
                    let findings = ([outcome.assessment.summary] + outcome.assessment.concerns)
                        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    return finish(blocked(
                        findings: findings,
                        stage: .llmReview,
                        started: started,
                        parsed: parsed,
                        assessment: outcome.assessment
                    ), logger: logger)
                }
            } catch {
                return finish(blocked(
                    findings: ["Reviewer failed: \(error.localizedDescription)"],
                    stage: .llmReview,
                    started: started,
                    parsed: parsed
                ), logger: logger)
            }
        } else {
            logger("[script_exec] skipping LLM reviewer")
        }

        let timeout = SwiftScriptPreparer.effectiveScriptTimeoutSeconds(
            requested: parsed.timeoutSeconds
        )
        let executor = SwiftDockerExecutor(executor: stdinExecutor)
        let invokeID = UUID().uuidString
        do {
            let artifact = try await executor.compile(source: parsed.script)
            let result = try await hopLoop(
                artifact: artifact,
                executor: executor,
                initialEvent: initialEvent,
                invokeID: invokeID,
                timeoutSeconds: timeout,
                logger: logger,
                hopHandler: hopHandler
            )
            let metrics = ScriptPhaseTiming.scriptMetrics(parsed.script)
            var phaseTiming = result.phaseTiming ?? ScriptPhaseTiming()
            phaseTiming.staticValidateMS = staticValidateMS
            phaseTiming.totalMS = ScriptPhaseTiming.elapsedMS(from: started)
            phaseTiming.scriptCharCount = metrics.chars
            phaseTiming.scriptLineCount = metrics.lines
            phaseTiming.applyReviewerTiming(reviewerTiming)
            let decorated = ScriptExecutionResult(
                status: result.status,
                decision: result.decision,
                failureStage: result.failureStage,
                verifier: "swift-check-v1",
                validationFindings: result.validationFindings,
                reviewerAssessment: reviewerAssessment,
                stdout: result.stdout,
                stderr: result.stderr,
                exitCode: result.exitCode,
                timedOut: result.timedOut,
                durationMS: phaseTiming.totalMS,
                phaseTiming: phaseTiming
            )
            return finish(decorated, logger: logger)
        } catch let error as SwiftDockerExecutorError {
            let stage: ScriptFailureStage
            switch error {
            case .commandFailed(let step, _) where step == "swiftc":
                stage = .typecheck
            default:
                stage = .execution
            }
            logger("[script_exec] Swift runtime failed stage=\(stage.rawValue): \(error.localizedDescription)")
            return finish(runtimeFailure(
                findings: [error.localizedDescription],
                stage: stage,
                started: started,
                parsed: parsed,
                assessment: reviewerAssessment
            ), logger: logger)
        } catch {
            logger("[script_exec] Swift runtime failed: \(error.localizedDescription)")
            return finish(runtimeFailure(
                findings: [error.localizedDescription],
                stage: .execution,
                started: started,
                parsed: parsed,
                assessment: reviewerAssessment
            ), logger: logger)
        }
    }

    private static func hopLoop(
        artifact: Data,
        executor: SwiftDockerExecutor,
        initialEvent: PluginHopEvent,
        invokeID: String,
        timeoutSeconds: Int,
        logger: @escaping @Sendable (String) -> Void,
        hopHandler: (any PluginHopHandler)?
    ) async throws -> ScriptExecutionResult {
        var event = initialEvent
        var posts: [String] = []
        var lastTitle = ""
        var lastSummary = ""

        for _ in 0..<PluginContract.maxHops {
            let input = try JSONEncoder().encode(event)
            let hopResult = try await executor.runArtifact(
                artifact,
                input: input,
                timeoutSeconds: timeoutSeconds
            )
            let stdout = String(decoding: hopResult.stdout, as: UTF8.self)
            let stderr = String(decoding: hopResult.stderr, as: UTF8.self)
            guard hopResult.exitCode == 0 else {
                return ScriptExecutionResult.runnerOutcome(
                    timedOut: false,
                    exitCode: hopResult.exitCode,
                    stdout: stdout,
                    stderr: stderr,
                    durationMS: 0,
                    phaseTiming: nil,
                    verifier: "swift-check-v1"
                )
            }

            let envelopes = try PluginEnvelopeList.decode(hopResult.stdout)
            let requests = envelopes.filter { $0.verb == .httpRequest }
            let uiPresents = envelopes.filter { $0.verb == .uiPresent }
            let secretRequests = envelopes.filter { $0.verb == .secretRequest }
            let terminals = envelopes.filter { $0.verb.classification == .terminal }

            for envelope in envelopes where envelope.verb == .log {
                logger("[script_exec] \(envelope.payload["message"]?.stringValue ?? "")")
            }
            for envelope in envelopes where envelope.verb == .messagePost {
                if let text = envelope.payload["text"]?.stringValue {
                    posts.append(text)
                }
            }
            for envelope in envelopes where envelope.verb == .resultEmit {
                if let title = envelope.payload["title"]?.stringValue, !title.isEmpty {
                    lastTitle = title
                }
                lastSummary = envelope.payload["summary"]?.stringValue
                    ?? envelope.payload["content"]?.stringValue
                    ?? envelope.payload["html"]?.stringValue
                    ?? envelope.payload["text"]?.stringValue
                    ?? envelope.payload["title"]?.stringValue
                    ?? lastSummary
            }

            if !requests.isEmpty {
                guard let nextData = await PluginHostHopDispatcher.httpResultEvent(
                    for: envelopes,
                    invokeID: invokeID,
                    params: event.params
                ) else {
                    return ScriptExecutionResult(
                        status: .failed,
                        decision: .allow,
                        failureStage: .execution,
                        verifier: "swift-check-v1",
                        validationFindings: ["Host could not prepare HTTP results."],
                        reviewerAssessment: nil,
                        stdout: stdout,
                        stderr: stderr,
                        exitCode: -1,
                        timedOut: false,
                        durationMS: 0,
                        phaseTiming: nil
                    )
                }
                event = try JSONDecoder().decode(PluginHopEvent.self, from: nextData)
                continue
            }

            if !uiPresents.isEmpty {
                if let next = await hopHandler?.handleUIPresent(payload: uiPresents[0].payload) {
                    event = next
                    continue
                }
                let cardText = uiPresentText(uiPresents[0].payload)
                return ScriptExecutionResult.runnerOutcome(
                    timedOut: false,
                    exitCode: 0,
                    stdout: terminalStdout(
                        posts: posts,
                        title: lastTitle,
                        summary: lastSummary,
                        extra: cardText
                    ),
                    stderr: stderr,
                    durationMS: 0,
                    phaseTiming: nil,
                    verifier: "swift-check-v1"
                )
            }

            if !secretRequests.isEmpty {
                if let next = await hopHandler?.handleSecretRequest(payload: secretRequests[0].payload) {
                    event = next
                    continue
                }
                return ScriptExecutionResult(
                    status: .failed,
                    decision: .allow,
                    failureStage: .execution,
                    verifier: "swift-check-v1",
                    validationFindings: [
                        "Script requested a secret. Add it in Settings, then run again."
                    ],
                    reviewerAssessment: nil,
                    stdout: stdout,
                    stderr: stderr,
                    exitCode: -1,
                    timedOut: false,
                    durationMS: 0,
                    phaseTiming: nil
                )
            }

            if !terminals.isEmpty {
                return ScriptExecutionResult.runnerOutcome(
                    timedOut: false,
                    exitCode: 0,
                    stdout: terminalStdout(
                        posts: posts,
                        title: lastTitle,
                        summary: lastSummary
                    ),
                    stderr: stderr,
                    durationMS: 0,
                    phaseTiming: nil,
                    verifier: "swift-check-v1"
                )
            }

            return ScriptExecutionResult(
                status: .failed,
                decision: .allow,
                failureStage: .execution,
                verifier: "swift-check-v1",
                validationFindings: ["Swift script returned no terminal envelope."],
                reviewerAssessment: nil,
                stdout: stdout,
                stderr: stderr,
                exitCode: -1,
                timedOut: false,
                durationMS: 0,
                phaseTiming: nil
            )
        }

        return ScriptExecutionResult(
            status: .failed,
            decision: .allow,
            failureStage: .execution,
            verifier: "swift-check-v1",
            validationFindings: ["Hop budget exceeded."],
            reviewerAssessment: nil,
            stdout: "",
            stderr: "",
            exitCode: -1,
            timedOut: false,
            durationMS: 0,
            phaseTiming: nil
        )
    }

    private struct Parsed {
        var description: String
        var reason: String
        var script: String
        var userPrompt: String?
        var dependencies: [String: String]
        var timeoutSeconds: Int
    }

    private static func parse(_ arguments: [String: Value]) throws -> Parsed {
        func string(_ key: String) -> String? {
            arguments[key]?.stringValue
        }

        guard let description = string("description"), !description.isEmpty,
              let reason = string("reason"), !reason.isEmpty,
              let script = string("script"), !script.isEmpty else {
            throw NSError(
                domain: "MCPServer",
                code: 400,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "script_exec requires description, reason, and Swift script."
                ]
            )
        }

        var dependencies: [String: String] = [:]
        if case .object(let object)? = arguments["dependencies"] {
            for (key, value) in object {
                if let spec = value.stringValue {
                    dependencies[key] = spec
                }
            }
        }
        let timeout = arguments["timeout_seconds"]?.intValue ?? 60
        return Parsed(
            description: description,
            reason: reason,
            script: script,
            userPrompt: string("user_prompt"),
            dependencies: dependencies,
            timeoutSeconds: timeout
        )
    }

    private static func blocked(
        findings: [String],
        stage: ScriptFailureStage,
        started: Date,
        parsed: Parsed,
        assessment: ScriptReviewAssessment? = nil
    ) -> ScriptExecutionResult {
        ScriptExecutionResult(
            status: .blocked,
            decision: .deny,
            failureStage: stage,
            verifier: "swift-check-v1",
            validationFindings: findings,
            reviewerAssessment: assessment,
            stdout: "",
            stderr: "",
            exitCode: -1,
            timedOut: false,
            durationMS: ScriptPhaseTiming.elapsedMS(from: started),
            phaseTiming: nil
        )
    }

    private static func runtimeFailure(
        findings: [String],
        stage: ScriptFailureStage,
        started: Date,
        parsed: Parsed,
        assessment: ScriptReviewAssessment?
    ) -> ScriptExecutionResult {
        ScriptExecutionResult(
            status: .failed,
            decision: .allow,
            failureStage: stage,
            verifier: "swift-check-v1",
            validationFindings: findings,
            reviewerAssessment: assessment,
            stdout: "",
            stderr: findings.joined(separator: "\n"),
            exitCode: -1,
            timedOut: false,
            durationMS: ScriptPhaseTiming.elapsedMS(from: started),
            phaseTiming: ScriptPhaseTiming(
                scriptCharCount: parsed.script.utf8.count,
                scriptLineCount: ScriptPhaseTiming.scriptMetrics(parsed.script).lines
            )
        )
    }

    private static func terminalStdout(
        posts: [String],
        title: String,
        summary: String,
        extra: String = ""
    ) -> String {
        var parts: [String] = []
        if !title.isEmpty, !summary.localizedCaseInsensitiveContains(title) {
            parts.append("**\(title)**")
        }
        parts.append(contentsOf: posts)
        if !extra.isEmpty {
            parts.append(extra)
        }
        if !summary.isEmpty {
            parts.append(summary)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func uiPresentText(_ payload: [String: PluginJSON]) -> String {
        let title = payload["title"]?.stringValue ?? "Plugin"
        let body = payload["markdown"]?.stringValue
            ?? payload["summary"]?.stringValue
            ?? payload["text"]?.stringValue
            ?? payload["html"]?.stringValue
            ?? ""
        return body.isEmpty ? title : "\(title)\n\(body)"
    }

    private static func finish(
        _ result: ScriptExecutionResult,
        logger: @escaping @Sendable (String) -> Void
    ) -> String {
        let findings = result.validationFindings
            .joined(separator: " | ")
            .prefix(500)
        let findingSuffix = findings.isEmpty ? "" : " findings=\(findings)"
        let timing = result.phaseTiming.map {
            " static_ms=\($0.staticValidateMS) reviewer_ms=\($0.reviewerMS) " +
            "ensure_ms=\($0.ensureMS) exec_ms=\($0.execMS) total_ms=\($0.totalMS)"
        } ?? ""
        logger(
            "[script_exec] result status=\(result.status.rawValue) " +
            "decision=\(result.decision.rawValue) " +
            "failure_stage=\(result.failureStage.rawValue) " +
            "exit_code=\(result.exitCode) timed_out=\(result.timedOut) " +
            "stdout_chars=\(result.stdout.utf8.count) stderr_chars=\(result.stderr.utf8.count) " +
            "duration_ms=\(result.durationMS)\(timing)\(findingSuffix)"
        )
        return encode(result.toolExecutionOutcome())
    }

    private static func encode(_ outcome: ToolExecutionOutcome) -> String {
        MCPServerHost.encodeJSON(outcome)
    }
}

private extension Value {
    var intValue: Int? {
        switch self {
        case .int(let value):
            return value
        case .double(let value):
            return Int(value)
        default:
            return nil
        }
    }
}
