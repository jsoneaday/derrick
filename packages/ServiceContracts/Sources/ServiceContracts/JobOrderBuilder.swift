import Foundation

/// Validated inputs for placing a one-shot job order (agent or UI).
public struct JobCreateOrderInput: Sendable, Hashable {
    public var runAfterSeconds: Int?
    /// Absolute fire time (preferred when both set: `runAt` wins).
    public var runAt: Date?
    public var toolName: String
    public var toolArgumentsJSON: String
    public var wakeAfter: Bool
    public var wakePrompt: String?
    public var description: String?

    public init(
        runAfterSeconds: Int? = nil,
        runAt: Date? = nil,
        toolName: String,
        toolArgumentsJSON: String,
        wakeAfter: Bool = true,
        wakePrompt: String? = nil,
        description: String? = nil
    ) {
        self.runAfterSeconds = runAfterSeconds
        self.runAt = runAt
        self.toolName = toolName
        self.toolArgumentsJSON = toolArgumentsJSON
        self.wakeAfter = wakeAfter
        self.wakePrompt = wakePrompt
        self.description = description
    }
}

/// Validated inputs for a schedule template.
public struct JobScheduleOrderInput: Sendable, Hashable {
    public var name: String
    /// `once` or `interval`
    public var recurrenceKind: JobRecurrenceKind
    public var intervalSeconds: Int?
    public var runAfterSeconds: Int?
    public var nextFireAt: Date?
    public var toolName: String
    public var toolArgumentsJSON: String
    public var wakeAfter: Bool
    public var wakePrompt: String?
    public var enabled: Bool

    public init(
        name: String,
        recurrenceKind: JobRecurrenceKind,
        intervalSeconds: Int? = nil,
        runAfterSeconds: Int? = nil,
        nextFireAt: Date? = nil,
        toolName: String,
        toolArgumentsJSON: String,
        wakeAfter: Bool = true,
        wakePrompt: String? = nil,
        enabled: Bool = true
    ) {
        self.name = name
        self.recurrenceKind = recurrenceKind
        self.intervalSeconds = intervalSeconds
        self.runAfterSeconds = runAfterSeconds
        self.nextFireAt = nextFireAt
        self.toolName = toolName
        self.toolArgumentsJSON = toolArgumentsJSON
        self.wakeAfter = wakeAfter
        self.wakePrompt = wakePrompt
        self.enabled = enabled
    }
}

public enum JobOrderBuilderError: Error, LocalizedError, Sendable, Equatable {
    case emptyToolName
    case toolNotAllowed(String)
    case invalidToolArgumentsJSON
    case wakePromptRequired
    case invalidRunAfterSeconds(Int)
    case invalidIntervalSeconds(Int)
    case emptyScheduleName
    case invalidRecurrence

    public var errorDescription: String? {
        switch self {
        case .emptyToolName: return "tool_name is required."
        case .toolNotAllowed(let n): return "tool_name '\(n)' is not allowed for jobs (v1: python_script_exec only)."
        case .invalidToolArgumentsJSON: return "tool_arguments must be a JSON object."
        case .wakePromptRequired: return "wake_prompt is required when wake_after is true."
        case .invalidRunAfterSeconds(let s): return "run_after_seconds out of range: \(s) (allow 0...86400)."
        case .invalidIntervalSeconds(let s): return "interval_seconds must be >= 60 (got \(s))."
        case .emptyScheduleName: return "name is required for schedules."
        case .invalidRecurrence: return "recurrence must be once or interval (interval needs interval_seconds)."
        }
    }
}

/// Pure mapping: agent order intents → JobService create requests.
public enum JobOrderBuilder {
    /// Effectors the agent may freeze into a job (expand later).
    public static let allowedToolNames: Set<String> = ["python_script_exec"]

    public static let maxRunAfterSeconds = 86_400

    public static func createJobRequest(
        from input: JobCreateOrderInput,
        principal: ServicePrincipal,
        source: JobSource = .agent,
        sessionID: String?,
        agentID: String?,
        helperAPIKey: String? = nil,
        helperReviewerModelJSON: String? = nil,
        now: Date = .now
    ) throws -> CreateJobRequest {
        try validateTool(input.toolName, argumentsJSON: input.toolArgumentsJSON)
        if input.wakeAfter {
            let prompt = input.wakePrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !prompt.isEmpty else { throw JobOrderBuilderError.wakePromptRequired }
        }
        if let s = input.runAfterSeconds, !(0...maxRunAfterSeconds).contains(s) {
            throw JobOrderBuilderError.invalidRunAfterSeconds(s)
        }

        let runAt = resolveFireDate(
            absolute: input.runAt,
            runAfterSeconds: input.runAfterSeconds,
            now: now
        )

        let argsJSON = input.toolName == "python_script_exec"
            ? normalizePythonScriptArgumentsJSON(input.toolArgumentsJSON)
            : input.toolArgumentsJSON

        let toolPayload = JobRunToolPayload(
            toolName: input.toolName,
            argumentsJSON: argsJSON,
            helperAPIKey: helperAPIKey,
            helperReviewerModelJSON: helperReviewerModelJSON
        )

        let step: CreateJobStepSpec
        if input.wakeAfter {
            // Branch memory: job session is isolated from the live chat session.
            let jobSessionID = JobSessionID.make()
            let wake = JobWakeAgentPayload(
                prompt: input.wakePrompt ?? "",
                sessionID: jobSessionID,
                agentID: JobSessionID.agentID,
                apiKey: helperAPIKey,
                jobID: nil,
                parentSessionID: sessionID
            )
            step = try .runToolThenWake(JobRunToolThenWakePayload(tool: toolPayload, wake: wake))
        } else {
            step = try .runTool(toolPayload)
        }

        return CreateJobRequest(
            principal: principal,
            source: source,
            correlationId: input.description,
            scheduleID: nil,
            runAt: runAt,
            steps: [step]
        )
    }

    public static func createScheduleRequest(
        from input: JobScheduleOrderInput,
        principal: ServicePrincipal,
        source: JobSource = .agent,
        sessionID: String?,
        agentID: String?,
        helperAPIKey: String? = nil,
        helperReviewerModelJSON: String? = nil,
        now: Date = .now
    ) throws -> CreateScheduleRequest {
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw JobOrderBuilderError.emptyScheduleName }
        try validateTool(input.toolName, argumentsJSON: input.toolArgumentsJSON)
        if input.wakeAfter {
            let prompt = input.wakePrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !prompt.isEmpty else { throw JobOrderBuilderError.wakePromptRequired }
        }

        let recurrence: JobRecurrence
        switch input.recurrenceKind {
        case .once:
            recurrence = .once
        case .interval:
            guard let seconds = input.intervalSeconds, seconds >= 60 else {
                throw JobOrderBuilderError.invalidIntervalSeconds(input.intervalSeconds ?? 0)
            }
            recurrence = .every(seconds: seconds)
        }

        if let s = input.runAfterSeconds, !(0...maxRunAfterSeconds).contains(s) {
            throw JobOrderBuilderError.invalidRunAfterSeconds(s)
        }

        let nextFire = resolveFireDate(
            absolute: input.nextFireAt,
            runAfterSeconds: input.runAfterSeconds,
            now: now
        )

        let argsJSON = input.toolName == "python_script_exec"
            ? normalizePythonScriptArgumentsJSON(input.toolArgumentsJSON)
            : input.toolArgumentsJSON

        let toolPayload = JobRunToolPayload(
            toolName: input.toolName,
            argumentsJSON: argsJSON,
            helperAPIKey: helperAPIKey,
            helperReviewerModelJSON: helperReviewerModelJSON
        )

        let step: CreateJobStepSpec
        if input.wakeAfter {
            let jobSessionID = JobSessionID.make()
            let wake = JobWakeAgentPayload(
                prompt: input.wakePrompt ?? "",
                sessionID: jobSessionID,
                agentID: JobSessionID.agentID,
                apiKey: helperAPIKey,
                jobID: nil,
                parentSessionID: sessionID
            )
            step = try .runToolThenWake(JobRunToolThenWakePayload(tool: toolPayload, wake: wake))
        } else {
            step = try .runTool(toolPayload)
        }

        return CreateScheduleRequest(
            name: name,
            principal: principal,
            source: source,
            recurrence: recurrence,
            steps: [step],
            nextFireAt: nextFire,
            enabled: input.enabled
        )
    }

    /// Absolute time wins; else now + seconds; else nil (ASAP).
    public static func resolveFireDate(
        absolute: Date?,
        runAfterSeconds: Int?,
        now: Date = .now
    ) -> Date? {
        if let absolute { return absolute }
        if let seconds = runAfterSeconds {
            if seconds <= 0 { return nil }
            return now.addingTimeInterval(TimeInterval(seconds))
        }
        return nil
    }

    /// Parse ISO-8601 or common local formats into `Date`.
    public static func parseRunAtString(_ raw: String, now: Date = .now, calendar: Calendar = .current) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: trimmed) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: trimmed) { return d }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = calendar.timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            df.dateFormat = format
            if let d = df.date(from: trimmed) { return d }
        }

        // "3:00 PM" / "15:00" → next occurrence today/tomorrow local
        df.dateFormat = "h:mm a"
        if let t = df.date(from: trimmed) {
            return nextTimeOfDay(from: t, now: now, calendar: calendar)
        }
        df.dateFormat = "H:mm"
        if let t = df.date(from: trimmed) {
            return nextTimeOfDay(from: t, now: now, calendar: calendar)
        }
        return nil
    }

    private static func nextTimeOfDay(from time: Date, now: Date, calendar: Calendar) -> Date {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: time)
        var today = calendar.dateComponents([.year, .month, .day], from: now)
        today.hour = parts.hour
        today.minute = parts.minute
        today.second = parts.second ?? 0
        guard let candidate = calendar.date(from: today) else { return now }
        if candidate > now { return candidate }
        return calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
    }

    private static func validateTool(_ name: String, argumentsJSON: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw JobOrderBuilderError.emptyToolName }
        guard allowedToolNames.contains(trimmed) else {
            throw JobOrderBuilderError.toolNotAllowed(trimmed)
        }
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              obj is [String: Any]
        else {
            throw JobOrderBuilderError.invalidToolArgumentsJSON
        }
    }

    /// Ensure python_script_exec args include fields the MCP tool expects when the model omits them.
    public static func normalizePythonScriptArgumentsJSON(_ json: String) -> String {
        guard var dict = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            return json
        }
        let modeRaw = (dict["mode"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        switch modeRaw {
        case "readonly", "write":
            dict["mode"] = modeRaw
        default:
            dict["mode"] = "readonly"
        }
        if dict["allow_network"] == nil { dict["allow_network"] = false }
        if dict["description"] == nil { dict["description"] = "Scheduled job script" }
        if dict["reason"] == nil { dict["reason"] = "Background job" }
        if dict["user_prompt"] == nil { dict["user_prompt"] = "scheduled job" }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8)
        else { return json }
        return s
    }
}
