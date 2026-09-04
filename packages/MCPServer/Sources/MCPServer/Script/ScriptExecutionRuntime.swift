import Foundation
import MCP
import Plugin
import ServiceContracts

public protocol PluginHopHandler: Sendable {
    func handleUIPresent(payload: [String: PluginJSON]) async -> PluginHopEvent?
    func handleSecretRequest(payload: [String: PluginJSON]) async -> PluginHopEvent?
}

/// Runs standalone guest source (Python primary, Swift legacy) and dispatches host-owned capability hops.
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
        let language = GuestScriptLanguage.resolve(arguments: arguments, script: parsed.script)
        logger("[script_exec] \(language.rawValue) source chars=\(parsed.script.count)")

        let staticStarted = Date()
        let staticFindings = staticValidate(
            language: language,
            source: parsed.script,
            dependencies: parsed.dependencies
        )
        let staticValidateMS = ScriptPhaseTiming.elapsedMS(from: staticStarted)
        if !staticFindings.isEmpty {
            return finish(blocked(
                findings: staticFindings,
                stage: .staticValidation,
                started: started,
                parsed: parsed,
                verifier: language.verifierID
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
                    parsed: parsed,
                    verifier: language.verifierID
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
                    parsed: parsed,
                    verifier: language.verifierID
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
                        assessment: outcome.assessment,
                        verifier: language.verifierID
                    ), logger: logger)
                }
            } catch {
                return finish(blocked(
                    findings: ["Reviewer failed: \(error.localizedDescription)"],
                    stage: .llmReview,
                    started: started,
                    parsed: parsed,
                    verifier: language.verifierID
                ), logger: logger)
            }
        } else {
            logger("[script_exec] skipping LLM reviewer")
        }

        let timeout = SwiftScriptPreparer.effectiveScriptTimeoutSeconds(
            requested: parsed.timeoutSeconds
        )
        let invokeID = UUID().uuidString
        do {
            let result: ScriptExecutionResult
            switch language {
            case .python:
                let executor = PythonGuestDockerExecutor(executor: stdinExecutor)
                result = try await GuestHopLoop.run(
                    initialEvent: initialEvent,
                    invokeID: invokeID,
                    timeoutSeconds: timeout,
                    verifier: language.verifierID,
                    execute: { input in
                        try await executor.runSource(
                            source: parsed.script,
                            input: input,
                            timeoutSeconds: timeout
                        )
                    },
                    logger: logger,
                    hopHandler: hopHandler
                )
            case .swift:
                let executor = SwiftDockerExecutor(executor: stdinExecutor)
                let artifact = try await executor.compile(source: parsed.script)
                result = try await GuestHopLoop.run(
                    initialEvent: initialEvent,
                    invokeID: invokeID,
                    timeoutSeconds: timeout,
                    verifier: language.verifierID,
                    execute: { input in
                        try await executor.runArtifact(
                            artifact,
                            input: input,
                            timeoutSeconds: timeout
                        )
                    },
                    logger: logger,
                    hopHandler: hopHandler
                )
            }
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
                verifier: language.verifierID,
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
            logger("[script_exec] guest runtime failed stage=\(stage.rawValue): \(error.localizedDescription)")
            return finish(runtimeFailure(
                findings: [error.localizedDescription],
                stage: stage,
                started: started,
                parsed: parsed,
                assessment: reviewerAssessment,
                verifier: language.verifierID
            ), logger: logger)
        } catch let error as PythonGuestDockerExecutorError {
            logger("[script_exec] guest runtime failed: \(error.localizedDescription)")
            return finish(runtimeFailure(
                findings: [error.localizedDescription],
                stage: .execution,
                started: started,
                parsed: parsed,
                assessment: reviewerAssessment,
                verifier: language.verifierID
            ), logger: logger)
        } catch {
            logger("[script_exec] guest runtime failed: \(error.localizedDescription)")
            return finish(runtimeFailure(
                findings: [error.localizedDescription],
                stage: .execution,
                started: started,
                parsed: parsed,
                assessment: reviewerAssessment,
                verifier: language.verifierID
            ), logger: logger)
        }
    }

    private static func staticValidate(
        language: GuestScriptLanguage,
        source: String,
        dependencies: [String: String]
    ) -> [String] {
        switch language {
        case .python:
            return PythonScriptVerifier.validate(source: source, dependencies: dependencies)
        case .swift:
            return SwiftScriptVerifier.validate(source: source, dependencies: dependencies)
        }
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
                        "script_exec requires description, reason, and guest script source."
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
        assessment: ScriptReviewAssessment? = nil,
        verifier: String
    ) -> ScriptExecutionResult {
        ScriptExecutionResult(
            status: .blocked,
            decision: .deny,
            failureStage: stage,
            verifier: verifier,
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
        assessment: ScriptReviewAssessment?,
        verifier: String
    ) -> ScriptExecutionResult {
        ScriptExecutionResult(
            status: .failed,
            decision: .allow,
            failureStage: stage,
            verifier: verifier,
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
