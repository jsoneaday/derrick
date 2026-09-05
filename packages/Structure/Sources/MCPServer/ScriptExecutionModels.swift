import Foundation

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

/// Optional pre-run network gate (app-owned). Returns encoded blocked tool JSON, or nil to proceed.
public typealias ScriptNetworkPreflight = @Sendable (_ script: String, _ allowNetwork: Bool) async -> String?
