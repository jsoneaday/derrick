import Foundation

/// Common wire result for executable script and plugin tools.
///
/// Tool-specific models may retain richer internal state, but callers receive
/// this stable envelope at the MCP boundary.
public struct ToolExecutionOutcome: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable, Hashable {
        case completed
        case blocked
        case failed
        case timeout
    }

    public enum Stage: String, Codable, Sendable, Hashable {
        case none
        case validation
        case review
        case compilation
        case execution
        case network
        case timeout
        case persistence
    }

    public enum OutputFormat: String, Codable, Sendable, Hashable {
        case text
        case markdown
        case csv
        case html
        case json
    }

    public struct Output: Codable, Sendable, Hashable {
        public let format: OutputFormat
        public let value: String

        public init(format: OutputFormat, value: String) {
            self.format = format
            self.value = value
        }
    }

    public struct Diagnostic: Codable, Sendable, Hashable {
        public enum Severity: String, Codable, Sendable, Hashable {
            case info
            case warning
            case error
        }

        public let severity: Severity
        public let code: String
        public let message: String

        public init(
            severity: Severity = .error,
            code: String,
            message: String
        ) {
            self.severity = severity
            self.code = code
            self.message = message
        }
    }

    public struct Retry: Codable, Sendable, Hashable {
        public let allowed: Bool
        public let attempt: Int?
        public let maxAttempts: Int?

        public init(
            allowed: Bool,
            attempt: Int? = nil,
            maxAttempts: Int? = nil
        ) {
            self.allowed = allowed
            self.attempt = attempt
            self.maxAttempts = maxAttempts
        }
    }

    public struct Metrics: Codable, Sendable, Hashable {
        public let staticValidateMS: Int
        public let reviewerMS: Int
        public let ensureMS: Int
        public let execMS: Int
        public let totalMS: Int
        public let scriptCharCount: Int
        public let scriptLineCount: Int
        public let reviewerRequestChars: Int
        public let reviewerResponseChars: Int

        public init(
            staticValidateMS: Int = 0,
            reviewerMS: Int = 0,
            ensureMS: Int = 0,
            execMS: Int = 0,
            totalMS: Int = 0,
            scriptCharCount: Int = 0,
            scriptLineCount: Int = 0,
            reviewerRequestChars: Int = 0,
            reviewerResponseChars: Int = 0
        ) {
            self.staticValidateMS = staticValidateMS
            self.reviewerMS = reviewerMS
            self.ensureMS = ensureMS
            self.execMS = execMS
            self.totalMS = totalMS
            self.scriptCharCount = scriptCharCount
            self.scriptLineCount = scriptLineCount
            self.reviewerRequestChars = reviewerRequestChars
            self.reviewerResponseChars = reviewerResponseChars
        }
    }

    public let status: Status
    public let stage: Stage
    public let output: Output?
    public let diagnostics: [Diagnostic]
    public let retry: Retry?
    public let metrics: Metrics?
    public let exitCode: Int32?
    public let timedOut: Bool
    public let durationMS: Int?

    public var indicatesFailure: Bool {
        status != .completed
    }

    public init(
        status: Status,
        stage: Stage = .none,
        output: Output? = nil,
        diagnostics: [Diagnostic] = [],
        retry: Retry? = nil,
        metrics: Metrics? = nil,
        exitCode: Int32? = nil,
        timedOut: Bool = false,
        durationMS: Int? = nil
    ) {
        self.status = status
        self.stage = stage
        self.output = output
        self.diagnostics = diagnostics
        self.retry = retry
        self.metrics = metrics
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.durationMS = durationMS
    }

    public static func completed(
        output: Output,
        diagnostics: [Diagnostic] = [],
        metrics: Metrics? = nil,
        exitCode: Int32? = nil,
        timedOut: Bool = false,
        durationMS: Int? = nil
    ) -> ToolExecutionOutcome {
        ToolExecutionOutcome(
            status: .completed,
            output: output,
            diagnostics: diagnostics,
            metrics: metrics,
            exitCode: exitCode,
            timedOut: timedOut,
            durationMS: durationMS
        )
    }

    public static func failure(
        status: Status = .failed,
        stage: Stage,
        diagnostics: [Diagnostic],
        retry: Retry? = nil,
        metrics: Metrics? = nil,
        exitCode: Int32? = nil,
        timedOut: Bool = false,
        durationMS: Int? = nil
    ) -> ToolExecutionOutcome {
        ToolExecutionOutcome(
            status: status,
            stage: stage,
            diagnostics: diagnostics,
            retry: retry,
            metrics: metrics,
            exitCode: exitCode,
            timedOut: timedOut,
            durationMS: durationMS
        )
    }

    public var failureSummary: String? {
        guard indicatesFailure else { return nil }
        let reasons = diagnostics
            .map(\.message)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if reasons.isEmpty {
            return "status=\(status.rawValue) stage=\(stage.rawValue)"
        }
        return reasons.joined(separator: "; ")
    }

    public func encodedJSON() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(from text: String) -> ToolExecutionOutcome? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ToolExecutionOutcome.self, from: data)
    }
}
