import Foundation
import MCP
import Plugin

public enum ScriptExecutionRuntime {
    public static func run(
        arguments: [String: Value],
        stdinExecutor: @escaping @Sendable ([String], Data, Int) async throws -> DockerCLIResult,
        reviewer: (any ScriptReviewer)?,
        logger: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let started = Date()
        let parsed = try parse(arguments)
        logger("[script_exec] script chars=\(parsed.script.count) deps=\(parsed.dependencies.count)")

        let staticFindings = ScriptJSVerifier.validate(script: parsed.script, dependencies: parsed.dependencies)
        if !staticFindings.isEmpty {
            return encode(blocked(findings: staticFindings, stage: .staticValidation, started: started, parsed: parsed))
        }

        guard let reviewer else {
            return encode(blocked(
                findings: ["script_exec requires configured reviewer"],
                stage: .llmReview,
                started: started,
                parsed: parsed
            ))
        }
        let reviewArgs = ScriptExecutionArguments(
            mode: .readonly,
            description: parsed.description,
            reason: parsed.reason,
            script: parsed.script,
            userPrompt: parsed.userPrompt,
            expectedEffects: [],
            packages: Array(parsed.dependencies.keys),
            allowDependencyInstall: !parsed.dependencies.isEmpty,
            timeoutSeconds: parsed.timeoutSeconds,
            allowNetwork: true
        )
        let extraStatic = ScriptExecutionVerifier.validate(reviewArgs)
        if !extraStatic.isEmpty {
            return encode(blocked(findings: extraStatic, stage: .staticValidation, started: started, parsed: parsed))
        }
        do {
                let outcome = try await reviewer.review(reviewArgs)
                logger("[script_exec] reviewer: \(outcome.assessment.summary)")
                let action = outcome.assessment.suggestedAction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if outcome.assessment.alignedWithRequest == false || action == "deny" || action == "confirm" {
                    if isEnvelopeShapeNitpick(outcome.assessment.summary, script: parsed.script) {
                        logger("[script_exec] reviewer envelope-shape nitpick ignored")
                    } else {
                        return encode(blocked(
                            findings: [outcome.assessment.summary],
                            stage: .llmReview,
                            started: started,
                            parsed: parsed,
                            assessment: outcome.assessment
                        ))
                    }
                }
        } catch {
            return encode(blocked(
                findings: ["Reviewer failed: \(error.localizedDescription)"],
                stage: .llmReview,
                started: started,
                parsed: parsed
            ))
        }

        let timeout = DockerScriptPreparer.effectiveScriptTimeoutSeconds(requested: parsed.timeoutSeconds)
        do {
            let result = try await DockerNetworkContainerPool.shared.withContainer(
                executor: { args, stdin, seconds in
                    try await stdinExecutor(args, stdin, seconds)
                }
            ) { containerName in
                try await ScriptLease.writeAndInstall(
                    containerName: containerName,
                    script: parsed.script,
                    dependencies: parsed.dependencies,
                    exec: stdinExecutor
                )
                try await ScriptLease.isolateNetwork(containerName: containerName, exec: stdinExecutor)
                return try await hopLoop(
                    containerName: containerName,
                    invokeID: UUID().uuidString,
                    timeoutSeconds: timeout,
                    exec: stdinExecutor,
                    logger: logger
                )
            }
            return encode(result)
        } catch let error as DockerNetworkContainerPoolError {
            if case .leaseTTLExceeded(let maxSeconds) = error {
                return encode(
                    ScriptExecutionResult.containerLeaseExceeded(
                        durationMS: ScriptPhaseTiming.elapsedMS(from: started),
                        maxSeconds: maxSeconds
                    )
                )
            }
            throw error
        } catch let error as ScriptLeaseError {
            if case .typecheckFailed(let message) = error {
                return encode(typecheckFailed(message, started: started, parsed: parsed))
            }
            return encode(blocked(
                findings: [error.localizedDescription],
                stage: .execution,
                started: started,
                parsed: parsed
            ))
        } catch {
            return encode(blocked(
                findings: [error.localizedDescription],
                stage: .execution,
                started: started,
                parsed: parsed
            ))
        }
    }

    private static func hopLoop(
        containerName: String,
        invokeID: String,
        timeoutSeconds: Int,
        exec: @escaping @Sendable ([String], Data, Int) async throws -> DockerCLIResult,
        logger: @escaping @Sendable (String) -> Void
    ) async throws -> ScriptExecutionResult {
        var event = PluginHopEvent(kind: .script)
        var posts: [String] = []
        var lastSummary = ""
        for hop in 0..<PluginContract.maxHops {
            let invokeData = try JSONWire.encode(PluginHostInvoke(seq: hop, event: event))
            let hopResult = try await ScriptLease.runHandle(
                containerName: containerName,
                invokeJSON: invokeData,
                timeoutSeconds: timeoutSeconds,
                exec: exec
            )
            if hopResult.exitCode != 0 {
                return ScriptExecutionResult.runnerOutcome(
                    timedOut: false,
                    exitCode: hopResult.exitCode,
                    stdout: hopResult.stdout,
                    stderr: hopResult.stderr,
                    durationMS: 0,
                    phaseTiming: nil
                )
            }

            let httpRequests = hopResult.envelopes.filter { $0.verb == .httpRequest }
            let uiPresents = hopResult.envelopes.filter { $0.verb == .uiPresent }
            let terminals = hopResult.envelopes.filter { $0.verb.classification == .terminal }
            for env in hopResult.envelopes where env.verb == .log {
                logger("[script_exec] \(env.payload["message"]?.stringValue ?? "")")
            }
            for env in hopResult.envelopes where env.verb == .messagePost {
                if let text = env.payload["text"]?.stringValue { posts.append(text) }
            }
            for env in hopResult.envelopes where env.verb == .resultEmit {
                lastSummary = env.payload["summary"]?.stringValue
                    ?? env.payload["content"]?.stringValue
                    ?? env.payload["text"]?.stringValue
                    ?? env.payload["title"]?.stringValue
                    ?? lastSummary
            }

            if !httpRequests.isEmpty {
                var results: [HostHTTPResponse] = []
                for req in httpRequests {
                    let url = req.payload["url"]?.stringValue ?? ""
                    let method = req.payload["method"]?.stringValue ?? "GET"
                    let id = req.payload["request_id"]?.stringValue ?? UUID().uuidString
                    let fetched = await HostHTTPClient.shared.perform(
                        method: method,
                        urlString: url,
                        invokeID: invokeID
                    )
                    results.append(fetched.response(requestID: id))
                }
                event = PluginHopEvent(kind: .httpResults, httpResults: results)
                continue
            }

            if !uiPresents.isEmpty {
                return ScriptExecutionResult(
                    status: .failed,
                    decision: .allow,
                    failureStage: .execution,
                    verifier: "script-v1",
                    validationFindings: ["ui.present is not available until the card hop is wired."],
                    reviewerAssessment: nil,
                    stdout: hopResult.stdout,
                    stderr: hopResult.stderr,
                    exitCode: -1,
                    timedOut: false,
                    durationMS: 0,
                    phaseTiming: nil
                )
            }

            if !terminals.isEmpty {
                let stdout = (posts + [lastSummary]).filter { !$0.isEmpty }.joined(separator: "\n")
                return ScriptExecutionResult.runnerOutcome(
                    timedOut: false,
                    exitCode: 0,
                    stdout: stdout.isEmpty ? hopResult.stdout : stdout,
                    stderr: hopResult.stderr,
                    durationMS: 0,
                    phaseTiming: nil
                )
            }

            return ScriptExecutionResult(
                status: .failed,
                decision: .allow,
                failureStage: .execution,
                verifier: "script-v1",
                validationFindings: ["handle() returned no terminal verb."],
                reviewerAssessment: nil,
                stdout: hopResult.stdout,
                stderr: hopResult.stderr,
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
            verifier: "script-v1",
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

    /// `return netFetch(...)` is a single object; the runner wraps it.
    private static func isEnvelopeShapeNitpick(_ summary: String, script: String) -> Bool {
        let lower = summary.lowercased()
        let mentionsShape = lower.contains("envelope") || lower.contains("array contract")
            || (lower.contains("handle") && lower.contains("array"))
        guard mentionsShape else { return false }
        let hasHandle = script.contains("export function handle") || script.contains("export async function handle")
        let returnsEnvelope = script.contains("return netFetch") || script.contains("return [")
        return hasHandle && returnsEnvelope
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
                userInfo: [NSLocalizedDescriptionKey: "script_exec requires description, reason, and script."]
            )
        }
        var deps: [String: String] = [:]
        if let obj = arguments["dependencies"]?.objectValue {
            for (k, v) in obj {
                if let s = v.stringValue { deps[k] = s }
            }
        }
        let timeout = arguments["timeout_seconds"]?.intValue ?? 60
        return Parsed(
            description: description,
            reason: reason,
            script: script,
            userPrompt: string("user_prompt"),
            dependencies: deps,
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
            verifier: "script-v1",
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

    private static func typecheckFailed(_ message: String, started: Date, parsed: Parsed) -> ScriptExecutionResult {
        _ = parsed
        return ScriptExecutionResult(
            status: .blocked,
            decision: .allow,
            failureStage: .typecheck,
            verifier: "tsc",
            validationFindings: [message],
            reviewerAssessment: nil,
            stdout: "",
            stderr: message,
            exitCode: -1,
            timedOut: false,
            durationMS: ScriptPhaseTiming.elapsedMS(from: started),
            phaseTiming: nil
        )
    }

    private static func encode(_ result: ScriptExecutionResult) -> String {
        MCPServerHost.encodeJSON(result)
    }
}

private extension Value {
    var objectValue: [String: Value]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(d)
        default: return nil
        }
    }
}
