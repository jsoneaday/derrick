import Foundation
import LLMAgentClient
import MCP
import ServiceContracts

public struct ScriptExecutionArguments: Sendable {
    public enum Mode: String, Sendable {
        case readonly
        case write
    }

    public let mode: Mode
    public let description: String
    public let reason: String
    public let script: String
    public let userPrompt: String?
    public let expectedEffects: [String]
    public let dependencies: [String: String]
    public let timeoutSeconds: Int
    public let allowNetwork: Bool

    public init(
        mode: Mode,
        description: String,
        reason: String,
        script: String,
        userPrompt: String?,
        expectedEffects: [String],
        dependencies: [String: String] = [:],
        timeoutSeconds: Int,
        allowNetwork: Bool
    ) {
        self.mode = mode
        self.description = description
        self.reason = reason
        self.script = script
        self.userPrompt = userPrompt
        self.expectedEffects = expectedEffects
        self.dependencies = dependencies
        self.timeoutSeconds = timeoutSeconds
        self.allowNetwork = allowNetwork
    }
}

public enum ScriptExecutionStatus: String, Codable, Sendable {
    case completed
    case failed
    case timeout
    case blocked
}

public enum ScriptExecutionDecision: String, Codable, Sendable {
    case allow
    case deny
    case confirm
}

/// Which pipeline gate failed. Distinct from `decision` (policy allow/deny) and `status` (run outcome).
/// Runtime failures must not be reported as security-review denials.
public enum ScriptFailureStage: String, Codable, Sendable, Equatable {
    /// No failure (completed successfully, or status still in flight).
    case none
    /// Static verifier rejected the request before run.
    case staticValidation
    /// The Swift compiler rejected the script.
    case typecheck
    /// LLM security reviewer rejected (or could not complete when required).
    case llmReview
    /// Script ran and exited non-zero (not a pre-run policy deny).
    case execution
    /// Script timed out inside the container.
    case timeout
    /// Container lease TTL exceeded (anti-hoarding); distinct from script timeout.
    case containerLease
    /// Egress proxy / network policy blocked a destination during run.
    case egress
}

/// Sub-phase timings inside the LLM security reviewer call.
public struct ScriptReviewerTiming: Codable, Sendable, Equatable {
    public var ttfbMS: Int
    public var streamMS: Int
    public var decodeMS: Int
    public var totalMS: Int
    public var requestChars: Int
    public var responseChars: Int
    public var chunkCount: Int
    public var model: String

    public init(
        ttfbMS: Int = 0,
        streamMS: Int = 0,
        decodeMS: Int = 0,
        totalMS: Int = 0,
        requestChars: Int = 0,
        responseChars: Int = 0,
        chunkCount: Int = 0,
        model: String = ""
    ) {
        self.ttfbMS = ttfbMS
        self.streamMS = streamMS
        self.decodeMS = decodeMS
        self.totalMS = totalMS
        self.requestChars = requestChars
        self.responseChars = responseChars
        self.chunkCount = chunkCount
        self.model = model
    }

    public var summaryLine: String {
        "[TIME_METRIC] script_reviewer reviewer_model=\(model.isEmpty ? "?" : model) reviewer_ttfb_ms=\(ttfbMS) reviewer_stream_ms=\(streamMS) reviewer_decode_ms=\(decodeMS) reviewer_total_ms=\(totalMS) reviewer_request_chars=\(requestChars) reviewer_response_chars=\(responseChars) reviewer_chunks=\(chunkCount)"
    }
}

public struct ScriptReviewOutcome: Sendable {
    public let assessment: ScriptReviewAssessment
    public let timing: ScriptReviewerTiming

    public init(assessment: ScriptReviewAssessment, timing: ScriptReviewerTiming) {
        self.assessment = assessment
        self.timing = timing
    }
}

/// Wall-clock phase timings for `script_exec` bottleneck analysis.
public struct ScriptPhaseTiming: Codable, Sendable, Equatable {
    public var staticValidateMS: Int
    public var reviewerMS: Int
    public var ensureMS: Int
    public var execMS: Int
    public var totalMS: Int
    public var scriptCharCount: Int
    public var scriptLineCount: Int
    public var wrapperCharCount: Int
    public var reviewerTtfbMS: Int
    public var reviewerStreamMS: Int
    public var reviewerDecodeMS: Int
    public var reviewerRequestChars: Int
    public var reviewerResponseChars: Int
    public var reviewerChunkCount: Int
    public var reviewerModel: String

    public init(
        staticValidateMS: Int = 0,
        reviewerMS: Int = 0,
        ensureMS: Int = 0,
        execMS: Int = 0,
        totalMS: Int = 0,
        scriptCharCount: Int = 0,
        scriptLineCount: Int = 0,
        wrapperCharCount: Int = 0,
        reviewerTtfbMS: Int = 0,
        reviewerStreamMS: Int = 0,
        reviewerDecodeMS: Int = 0,
        reviewerRequestChars: Int = 0,
        reviewerResponseChars: Int = 0,
        reviewerChunkCount: Int = 0,
        reviewerModel: String = ""
    ) {
        self.staticValidateMS = staticValidateMS
        self.reviewerMS = reviewerMS
        self.ensureMS = ensureMS
        self.execMS = execMS
        self.totalMS = totalMS
        self.scriptCharCount = scriptCharCount
        self.scriptLineCount = scriptLineCount
        self.wrapperCharCount = wrapperCharCount
        self.reviewerTtfbMS = reviewerTtfbMS
        self.reviewerStreamMS = reviewerStreamMS
        self.reviewerDecodeMS = reviewerDecodeMS
        self.reviewerRequestChars = reviewerRequestChars
        self.reviewerResponseChars = reviewerResponseChars
        self.reviewerChunkCount = reviewerChunkCount
        self.reviewerModel = reviewerModel
    }

    public mutating func applyReviewerTiming(_ timing: ScriptReviewerTiming) {
        reviewerMS = timing.totalMS
        reviewerTtfbMS = timing.ttfbMS
        reviewerStreamMS = timing.streamMS
        reviewerDecodeMS = timing.decodeMS
        reviewerRequestChars = timing.requestChars
        reviewerResponseChars = timing.responseChars
        reviewerChunkCount = timing.chunkCount
        reviewerModel = timing.model
    }

    public var summaryLine: String {
        let base = "[TIME_METRIC] script_exec static_ms=\(staticValidateMS) reviewer_ms=\(reviewerMS) ensure_ms=\(ensureMS) exec_ms=\(execMS) total_ms=\(totalMS) script_chars=\(scriptCharCount) script_lines=\(scriptLineCount) wrapper_chars=\(wrapperCharCount)"
        guard !reviewerModel.isEmpty || reviewerTtfbMS > 0 || reviewerStreamMS > 0 || reviewerResponseChars > 0 else {
            return base
        }
        return base + " reviewer_model=\(reviewerModel.isEmpty ? "?" : reviewerModel) reviewer_ttfb_ms=\(reviewerTtfbMS) reviewer_stream_ms=\(reviewerStreamMS) reviewer_decode_ms=\(reviewerDecodeMS) reviewer_request_chars=\(reviewerRequestChars) reviewer_response_chars=\(reviewerResponseChars) reviewer_chunks=\(reviewerChunkCount)"
    }

    public static func scriptMetrics(_ script: String) -> (chars: Int, lines: Int) {
        let chars = script.utf8.count
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false).count
        return (chars, lines)
    }

    public static func elapsedMS(from start: Date, to end: Date = Date()) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000.0).rounded()))
    }
}

/// Internal state used while constructing the common `ToolExecutionOutcome`.
public struct ScriptExecutionResult: Sendable {
    public let status: ScriptExecutionStatus
    public let decision: ScriptExecutionDecision
    /// Explicit gate that failed. UI and callers must switch on this — never infer from `decision` + `reviewerAssessment`.
    public let failureStage: ScriptFailureStage
    public let verifier: String
    public let validationFindings: [String]
    public let reviewerAssessment: ScriptReviewAssessment?
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let timedOut: Bool
    public let durationMS: Int
    public let phaseTiming: ScriptPhaseTiming?

    public init(
        status: ScriptExecutionStatus,
        decision: ScriptExecutionDecision,
        failureStage: ScriptFailureStage = .none,
        verifier: String,
        validationFindings: [String],
        reviewerAssessment: ScriptReviewAssessment?,
        stdout: String,
        stderr: String,
        exitCode: Int32,
        timedOut: Bool,
        durationMS: Int,
        phaseTiming: ScriptPhaseTiming? = nil
    ) {
        self.status = status
        self.decision = decision
        self.failureStage = failureStage
        self.verifier = verifier
        self.validationFindings = validationFindings
        self.reviewerAssessment = reviewerAssessment
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.durationMS = durationMS
        self.phaseTiming = phaseTiming
    }

    /// Classify a post-run runner outcome. Policy already allowed execution; non-zero exit is not a security deny.
    public static func runnerOutcome(
        timedOut: Bool,
        exitCode: Int32,
        stdout: String,
        stderr: String,
        durationMS: Int,
        phaseTiming: ScriptPhaseTiming?,
        verifier: String = "swift-check-v1"
    ) -> ScriptExecutionResult {
        let combined = stdout + "\n" + stderr
        let looksLikeEgress = combined.localizedCaseInsensitiveContains("UNAUTHORIZED_EGRESS")
            || combined.localizedCaseInsensitiveContains("unauthorized egress")

        let status: ScriptExecutionStatus
        let failureStage: ScriptFailureStage
        if timedOut {
            status = .timeout
            failureStage = .timeout
        } else if exitCode == 0 {
            status = .completed
            failureStage = .none
        } else if looksLikeEgress {
            status = .failed
            failureStage = .egress
        } else {
            status = .failed
            failureStage = .execution
        }

        return ScriptExecutionResult(
            status: status,
            // Runtime outcome is not a policy decision; policy already allowed the run.
            decision: .allow,
            failureStage: failureStage,
            verifier: verifier,
            validationFindings: [],
            reviewerAssessment: nil,
            stdout: stdout,
            stderr: stderr,
            exitCode: exitCode,
            timedOut: timedOut,
            durationMS: durationMS,
            phaseTiming: phaseTiming
        )
    }

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

public struct ScriptReviewAssessment: Codable, Sendable {
    public let alignedWithRequest: Bool
    public let confidence: Double
    public let suggestedAction: String
    public let concerns: [String]
    public let summary: String

    public init(
        alignedWithRequest: Bool,
        confidence: Double,
        suggestedAction: String,
        concerns: [String],
        summary: String
    ) {
        self.alignedWithRequest = alignedWithRequest
        self.confidence = confidence
        self.suggestedAction = suggestedAction
        self.concerns = concerns
        self.summary = summary
    }
}

public extension ScriptExecutionResult {
    /// Converts the detailed script runtime result to the common MCP outcome.
    func toolExecutionOutcome() -> ToolExecutionOutcome {
        let status: ToolExecutionOutcome.Status
        switch self.status {
        case .completed:
            status = .completed
        case .blocked:
            status = .blocked
        case .failed:
            status = .failed
        case .timeout:
            status = .timeout
        }

        let stage: ToolExecutionOutcome.Stage
        switch failureStage {
        case .none:
            stage = .none
        case .staticValidation:
            stage = .validation
        case .typecheck:
            stage = .compilation
        case .llmReview:
            stage = .review
        case .execution:
            stage = .execution
        case .egress:
            stage = .network
        case .timeout, .containerLease:
            stage = .timeout
        }

        var diagnostics = validationFindings.map {
            ToolExecutionOutcome.Diagnostic(code: "script_validation", message: $0)
        }
        if diagnostics.isEmpty,
           !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diagnostics.append(
                ToolExecutionOutcome.Diagnostic(
                    code: "script_stderr",
                    message: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }
        if diagnostics.isEmpty, status != .completed {
            diagnostics.append(
                ToolExecutionOutcome.Diagnostic(
                    code: "script_failed",
                    message: "The script did not complete successfully."
                )
            )
        }

        let output = status == .completed && !stdout.isEmpty
            ? ToolExecutionOutcome.Output(format: .text, value: stdout)
            : nil
        let metrics = phaseTiming.map {
            ToolExecutionOutcome.Metrics(
                staticValidateMS: $0.staticValidateMS,
                reviewerMS: $0.reviewerMS,
                ensureMS: $0.ensureMS,
                execMS: $0.execMS,
                totalMS: $0.totalMS,
                scriptCharCount: $0.scriptCharCount,
                scriptLineCount: $0.scriptLineCount,
                reviewerRequestChars: $0.reviewerRequestChars,
                reviewerResponseChars: $0.reviewerResponseChars
            )
        }
        return ToolExecutionOutcome(
            status: status,
            stage: stage,
            output: output,
            diagnostics: diagnostics,
            metrics: metrics,
            exitCode: exitCode,
            timedOut: timedOut,
            durationMS: durationMS
        )
    }
}

public protocol ScriptReviewer: Sendable {
    var name: String { get }
    func review(_ args: ScriptExecutionArguments) async throws -> ScriptReviewOutcome
}

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

/// Optional pre-run network gate (app-owned). Returns encoded blocked tool JSON, or nil to proceed.
public typealias ScriptNetworkPreflight = @Sendable (_ script: String, _ allowNetwork: Bool) async -> String?

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
