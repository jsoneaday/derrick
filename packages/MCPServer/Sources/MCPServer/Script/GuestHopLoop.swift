import Foundation
import Plugin
import Structure

/// Shared host hop loop for offline guest programs (Python or Swift).
public enum GuestHopLoop: Sendable {
    public static func run(
        initialEvent: PluginHopEvent,
        invokeID: String,
        timeoutSeconds: Int,
        verifier: String,
        execute: @escaping @Sendable (Data) async throws -> PluginFactoryExecutionResult,
        logger: @escaping @Sendable (String) -> Void,
        hopHandler: (any PluginHopHandler)? = nil
    ) async throws -> ScriptExecutionResult {
        var event = initialEvent
        var posts: [String] = []
        var lastTitle = ""
        var lastSummary = ""

        for _ in 0..<PluginContract.maxHops {
            let input = try JSONEncoder().encode(event)
            let hopResult = try await execute(input)
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
                    verifier: verifier
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
                        verifier: verifier,
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
                    verifier: verifier
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
                    verifier: verifier,
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
                    verifier: verifier
                )
            }

            return ScriptExecutionResult(
                status: .failed,
                decision: .allow,
                failureStage: .execution,
                verifier: verifier,
                validationFindings: ["Guest program returned no terminal envelope."],
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
            verifier: verifier,
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

    /// Like `run`, but preserves the guest's raw envelope JSON on stdout for `plugin.invoke`.
    public static func runForPluginInvoke(
        initialEvent: PluginHopEvent,
        invokeID: String,
        timeoutSeconds: Int,
        execute: @escaping @Sendable (Data) async throws -> PluginFactoryExecutionResult,
        logger: @escaping @Sendable (String) -> Void,
        hopHandler: (any PluginHopHandler)? = nil
    ) async throws -> PluginFactoryExecutionResult {
        var event = initialEvent
        var lastResult = PluginFactoryExecutionResult(exitCode: 1)

        for _ in 0..<PluginContract.maxHops {
            let input = try JSONEncoder().encode(event)
            let hopResult = try await execute(input)
            lastResult = hopResult
            guard hopResult.exitCode == 0 else { return hopResult }

            let envelopes = try PluginEnvelopeList.decode(hopResult.stdout)
            let requests = envelopes.filter { $0.verb == .httpRequest }
            let uiPresents = envelopes.filter { $0.verb == .uiPresent }
            let secretRequests = envelopes.filter { $0.verb == .secretRequest }
            let terminals = envelopes.filter { $0.verb.classification == .terminal }

            for envelope in envelopes where envelope.verb == .log {
                logger("[plugin.invoke] \(envelope.payload["message"]?.stringValue ?? "")")
            }

            if !requests.isEmpty {
                guard let nextData = await PluginHostHopDispatcher.httpResultEvent(
                    for: envelopes,
                    invokeID: invokeID,
                    params: event.params
                ) else {
                    return PluginFactoryExecutionResult(
                        exitCode: 1,
                        stdout: hopResult.stdout,
                        stderr: Data("Host could not prepare HTTP results.".utf8)
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
                return hopResult
            }

            if !secretRequests.isEmpty {
                if let next = await hopHandler?.handleSecretRequest(payload: secretRequests[0].payload) {
                    event = next
                    continue
                }
                return PluginFactoryExecutionResult(
                    exitCode: 1,
                    stdout: hopResult.stdout,
                    stderr: Data(
                        "Plugin requested a secret. Add it in Settings, then run again.".utf8
                    )
                )
            }

            if !terminals.isEmpty {
                return hopResult
            }

            return PluginFactoryExecutionResult(
                exitCode: 1,
                stdout: hopResult.stdout,
                stderr: Data("Guest program returned no terminal envelope.".utf8)
            )
        }

        return PluginFactoryExecutionResult(
            exitCode: 1,
            stdout: lastResult.stdout,
            stderr: Data("Hop budget exceeded.".utf8)
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
}
