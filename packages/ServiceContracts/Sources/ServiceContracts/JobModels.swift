import Foundation

// MARK: - Step kinds (fire types)

/// One ordered unit of work inside a job.
public enum JobStepKind: String, Codable, Sendable, Hashable {
    /// Single frozen tool + args (0 LLM at fire).
    case runTool
    /// Several tool invocations in one step (MCP batch semantics).
    case runToolBatch
    /// Deliver prompt/envelope → agent turn (may call MCP).
    case wakeAgent
    /// Tool(s) then wake agent with result (atomic intent).
    case runToolThenWake
}

/// @available legacy alias used by older docs / ServiceMessage notes.
public typealias JobFireKind = JobStepKind

// MARK: - Status

public enum JobStatus: String, Codable, Sendable, Hashable {
    case pending
    case scheduled
    case running
    case succeeded
    case failed
    case cancelled
}

public enum JobStepStatus: String, Codable, Sendable, Hashable {
    case pending
    case running
    case succeeded
    case failed
    case skipped
}

/// Who created the job (audit).
public enum JobSource: String, Codable, Sendable, Hashable {
    case ui
    case agent
    case webhook
    case system
}

// MARK: - Payloads (JSON inside step.payloadJSON)

/// Payload for `runTool`.
public struct JobRunToolPayload: Codable, Sendable, Hashable {
    public let toolName: String
    /// JSON object string of tool arguments.
    public let argumentsJSON: String
    public let helperAPIKey: String?
    public let helperReviewerModelJSON: String?

    public init(
        toolName: String,
        argumentsJSON: String,
        helperAPIKey: String? = nil,
        helperReviewerModelJSON: String? = nil
    ) {
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.helperAPIKey = helperAPIKey
        self.helperReviewerModelJSON = helperReviewerModelJSON
    }
}

/// Payload for `runToolBatch`.
public struct JobRunToolBatchPayload: Codable, Sendable, Hashable {
    public let invocations: [JobRunToolPayload]

    public init(invocations: [JobRunToolPayload]) {
        self.invocations = invocations
    }
}

/// Payload for `wakeAgent`.
public struct JobWakeAgentPayload: Codable, Sendable, Hashable {
    public let prompt: String
    public let sessionID: String?
    public let agentID: String?
    /// Encoded LLM model choice JSON (same as AgentTurnRequest.modelJSON).
    public let modelJSON: Data?
    public let apiKey: String?

    public init(
        prompt: String,
        sessionID: String? = nil,
        agentID: String? = nil,
        modelJSON: Data? = nil,
        apiKey: String? = nil
    ) {
        self.prompt = prompt
        self.sessionID = sessionID
        self.agentID = agentID
        self.modelJSON = modelJSON
        self.apiKey = apiKey
    }
}

/// Payload for `runToolThenWake` (tool then notify agent with result).
public struct JobRunToolThenWakePayload: Codable, Sendable, Hashable {
    public let tool: JobRunToolPayload
    public let wake: JobWakeAgentPayload

    public init(tool: JobRunToolPayload, wake: JobWakeAgentPayload) {
        self.tool = tool
        self.wake = wake
    }
}

// MARK: - Records

public struct JobStepRecord: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let jobID: String
    public let index: Int
    public let kind: JobStepKind
    public var status: JobStepStatus
    /// Kind-specific payload JSON.
    public let payloadJSON: String
    public var resultJSON: String?
    public var errorMessage: String?
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(
        id: String = UUID().uuidString,
        jobID: String,
        index: Int,
        kind: JobStepKind,
        status: JobStepStatus = .pending,
        payloadJSON: String,
        resultJSON: String? = nil,
        errorMessage: String? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.jobID = jobID
        self.index = index
        self.kind = kind
        self.status = status
        self.payloadJSON = payloadJSON
        self.resultJSON = resultJSON
        self.errorMessage = errorMessage
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public struct JobRecord: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public var status: JobStatus
    public let principal: ServicePrincipal
    public let source: JobSource
    public let correlationId: String?
    /// When nil, job is runnable as soon as claimed (pending).
    public var runAt: Date?
    public let createdAt: Date
    public var updatedAt: Date
    public var errorMessage: String?
    public var steps: [JobStepRecord]

    public init(
        id: String = UUID().uuidString,
        status: JobStatus = .pending,
        principal: ServicePrincipal,
        source: JobSource,
        correlationId: String? = nil,
        runAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        errorMessage: String? = nil,
        steps: [JobStepRecord] = []
    ) {
        self.id = id
        self.status = status
        self.principal = principal
        self.source = source
        self.correlationId = correlationId
        self.runAt = runAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.errorMessage = errorMessage
        self.steps = steps
    }
}

// MARK: - Create request (API)

public struct CreateJobStepSpec: Codable, Sendable, Hashable {
    public let kind: JobStepKind
    public let payloadJSON: String

    public init(kind: JobStepKind, payloadJSON: String) {
        self.kind = kind
        self.payloadJSON = payloadJSON
    }

    public static func runTool(_ payload: JobRunToolPayload) throws -> CreateJobStepSpec {
        let data = try JSONEncoder.service.encode(payload)
        return CreateJobStepSpec(kind: .runTool, payloadJSON: String(data: data, encoding: .utf8) ?? "{}")
    }

    public static func runToolBatch(_ payload: JobRunToolBatchPayload) throws -> CreateJobStepSpec {
        let data = try JSONEncoder.service.encode(payload)
        return CreateJobStepSpec(kind: .runToolBatch, payloadJSON: String(data: data, encoding: .utf8) ?? "{}")
    }

    public static func wakeAgent(_ payload: JobWakeAgentPayload) throws -> CreateJobStepSpec {
        let data = try JSONEncoder.service.encode(payload)
        return CreateJobStepSpec(kind: .wakeAgent, payloadJSON: String(data: data, encoding: .utf8) ?? "{}")
    }

    public static func runToolThenWake(_ payload: JobRunToolThenWakePayload) throws -> CreateJobStepSpec {
        let data = try JSONEncoder.service.encode(payload)
        return CreateJobStepSpec(kind: .runToolThenWake, payloadJSON: String(data: data, encoding: .utf8) ?? "{}")
    }
}

public struct CreateJobRequest: Codable, Sendable, Hashable {
    public let principal: ServicePrincipal
    public let source: JobSource
    public let correlationId: String?
    /// Schedule; nil = run ASAP.
    public let runAt: Date?
    public let steps: [CreateJobStepSpec]

    public init(
        principal: ServicePrincipal,
        source: JobSource,
        correlationId: String? = nil,
        runAt: Date? = nil,
        steps: [CreateJobStepSpec]
    ) {
        self.principal = principal
        self.source = source
        self.correlationId = correlationId
        self.runAt = runAt
        self.steps = steps
    }
}

public struct CreateJobResult: Codable, Sendable, Hashable {
    public let ok: Bool
    public let job: JobRecord?
    public let message: String

    public init(ok: Bool, job: JobRecord? = nil, message: String = "ok") {
        self.ok = ok
        self.job = job
        self.message = message
    }
}

public struct CancelJobRequest: Codable, Sendable, Hashable {
    public let jobID: String

    public init(jobID: String) {
        self.jobID = jobID
    }
}

public struct GetJobRequest: Codable, Sendable, Hashable {
    public let jobID: String

    public init(jobID: String) {
        self.jobID = jobID
    }
}

public struct ListJobsRequest: Codable, Sendable, Hashable {
    public let limit: Int
    public let status: JobStatus?

    public init(limit: Int = 50, status: JobStatus? = nil) {
        self.limit = limit
        self.status = status
    }
}

public struct ListJobsResult: Codable, Sendable, Hashable {
    public let ok: Bool
    public let jobs: [JobRecord]
    public let message: String

    public init(ok: Bool, jobs: [JobRecord] = [], message: String = "ok") {
        self.ok = ok
        self.jobs = jobs
        self.message = message
    }
}
