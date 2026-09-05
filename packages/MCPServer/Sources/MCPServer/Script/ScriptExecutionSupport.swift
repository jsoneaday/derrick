import Foundation
import LLMAgentClient
import Structure

enum ScriptReviewerRuntime {
    static func reviewInput(from args: ScriptExecutionArguments) -> String {
        let payload: [String: Any] = [
            "mode": args.mode.rawValue,
            "description": args.description,
            "reason": args.reason,
            "script": args.script,
            "user_prompt": args.userPrompt ?? "",
            "expected_effects": args.expectedEffects,
            "dependencies": args.dependencies,
            "allow_network": args.allowNetwork,
            "timeout_seconds": args.timeoutSeconds,
            "scheduler": [
                "name": "Derrick JobService",
                "applies_delay": true,
                "note": "If this script is attached to a job, JobService waits (run_after_seconds / schedule) and then calls script_exec. The script itself must not sleep or implement the delay."
            ] as [String: Any]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        let json = String(decoding: data, as: UTF8.self)
        return """
        Review this declared script_exec tool call payload.
        Context: Derrick schedules delayed work with JobService. The payload below is only the script that runs when the job fires. Mentions of delay or schedule in reason/user_prompt describe the job, not missing sleep() in the script.
        \(json)
        """
    }

    static func decodeAssessment(from response: String) throws -> ScriptReviewAssessment {
        let normalized = normalizeJSONPayload(response)
        guard let data = normalized.data(using: .utf8) else {
            throw NSError(domain: "MCPServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Reviewer returned invalid UTF-8."])
        }
        return try JSONDecoder().decode(ScriptReviewAssessment.self, from: data)
    }

    static func normalizeJSONPayload(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```"),
           let start = trimmed.range(of: "{"),
           let end = trimmed.range(of: "}", options: .backwards),
           start.lowerBound < end.upperBound {
            return String(trimmed[start.lowerBound..<end.upperBound])
        }
        return trimmed
    }

    static func runStreamedReview(
        modelLabel: String,
        args: ScriptExecutionArguments,
        stream: AsyncThrowingStream<AgentStreamEvent, Error>
    ) async throws -> ScriptReviewOutcome {
        let userContent = reviewInput(from: args)
        let requestChars = ReviewerSystemPrompt.utf8.count + userContent.utf8.count
        print("[ScriptExecutionTool] Reviewer request started: model=\(modelLabel), mode=\(args.mode.rawValue), dependencies=\(args.dependencies.count), allowNetwork=\(args.allowNetwork), timeoutSeconds=\(args.timeoutSeconds), request_chars=\(requestChars)")

        let requestStarted = Date()
        var firstChunkAt: Date?
        var lastChunkAt: Date?
        var chunkCount = 0
        var completion = ""

        for try await event in stream {
            switch event {
            case .text(let chunk):
                let now = Date()
                if firstChunkAt == nil {
                    firstChunkAt = now
                }
                lastChunkAt = now
                chunkCount += 1
                completion += chunk
            case .usage:
                break
            }
        }

        let streamEnded = Date()
        let ttfbMS: Int
        let streamMS: Int
        if let first = firstChunkAt {
            ttfbMS = ScriptPhaseTiming.elapsedMS(from: requestStarted, to: first)
            streamMS = ScriptPhaseTiming.elapsedMS(from: first, to: lastChunkAt ?? streamEnded)
        } else {
            // No chunks: entire wait is queue/error path.
            ttfbMS = ScriptPhaseTiming.elapsedMS(from: requestStarted, to: streamEnded)
            streamMS = 0
        }

        let decodeStarted = Date()
        let assessment = try decodeAssessment(from: completion)
        let decodeMS = ScriptPhaseTiming.elapsedMS(from: decodeStarted)
        let totalMS = ScriptPhaseTiming.elapsedMS(from: requestStarted)

        let timing = ScriptReviewerTiming(
            ttfbMS: ttfbMS,
            streamMS: streamMS,
            decodeMS: decodeMS,
            totalMS: totalMS,
            requestChars: requestChars,
            responseChars: completion.utf8.count,
            chunkCount: chunkCount,
            model: modelLabel
        )

        print("[ScriptExecutionTool] Reviewer outcome: aligned=\(assessment.alignedWithRequest), confidence=\(assessment.confidence), suggestedAction=\(assessment.suggestedAction), concerns=\(assessment.concerns.count), summary=\(assessment.summary)")
        print(timing.summaryLine)
        return ScriptReviewOutcome(assessment: assessment, timing: timing)
    }
}

public enum ScriptExecutionVerifier {
    public static func validate(_ args: ScriptExecutionArguments) -> [String] {
        var findings: [String] = []

        if args.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            findings.append("Missing description.")
        }
        if args.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            findings.append("Missing reason.")
        }
        if args.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            findings.append("Script is empty.")
        }
        if args.timeoutSeconds <= 0 || args.timeoutSeconds > 300 {
            findings.append("timeout_seconds must be between 1 and 300.")
        }
        if args.mode == .write && args.expectedEffects.isEmpty {
            findings.append("Write mode requires expected_effects.")
        }
        if !args.dependencies.isEmpty {
            findings.append("Swift script dependencies are not supported.")
        }

        if args.mode == .readonly {
            findings.append(contentsOf: readonlyViolations(in: args.script))
        }

        return findings
    }

    private static func readonlyViolations(in script: String) -> [String] {
        let patterns: [(String, String)] = [
            (#"(?m)\b(FileManager|writeData|write\(to:|removeItem|moveItem|createDirectory)\b"#, "Readonly mode cannot mutate filesystem."),
            (#"(?m)\b(Process|URLSession|NWConnection|Socket)\b"#, "Readonly mode cannot execute nested commands or access the network.")
        ]
        return patterns.compactMap { pattern, message in
            script.range(of: pattern, options: .regularExpression) != nil ? message : nil
        }
    }
}

extension ScriptExecutionResult {
    /// Container lease TTL hit — run stopped to free the slot for other agents.
    public static func containerLeaseExceeded(
        durationMS: Int,
        maxSeconds: Int = SwiftScriptPreparer.containerRunMaxTTLSeconds,
        phaseTiming: ScriptPhaseTiming? = nil,
        verifier: String = "swift-check-v1"
    ) -> ScriptExecutionResult {
        let explanation = SwiftScriptPreparer.containerLeaseExceededExplanation(maxSeconds: maxSeconds)
        return ScriptExecutionResult(
            status: .timeout,
            decision: .allow,
            failureStage: .containerLease,
            verifier: verifier,
            validationFindings: [explanation],
            reviewerAssessment: nil,
            stdout: "",
            stderr: explanation,
            exitCode: -1,
            timedOut: true,
            durationMS: durationMS,
            phaseTiming: phaseTiming
        )
    }
}

public extension MCPServerHost {
    /// Register the Swift `script_exec` tool.
    func registerScriptExecutionTool(
        description: String? = nil,
        stdinExecutor: @escaping @Sendable ([String], Data, Int) async throws -> DockerCLIResult,
        reviewer: (any ScriptReviewer)? = GeminiScriptReviewer.fromEnvironment(),
        logger: @escaping @Sendable (String) -> Void = { _ in }
    ) async {
        await register(
            ScriptExecutionToolModule.makeRegistration(
                description: description,
                stdinExecutor: stdinExecutor,
                reviewer: reviewer,
                logger: logger
            )
        )
    }
}
