import Foundation

public enum ToolRunStatus: String, Codable, Sendable, Hashable {
    case accepted
    case running
    case completed
    case failed
    case cancelled
}

public enum WorkflowRunStatus: String, Codable, Sendable, Hashable {
    case running
    case completed
    case failed
    case cancelled
}

public struct WorkflowStartRequest: Codable, Sendable, Hashable {
    public let kind: WorkflowKind
    public let sessionID: String
    public let turnID: String?
    public let agentID: String
    public let inputJSON: String
    public let principal: ServicePrincipal

    public init(
        kind: WorkflowKind,
        sessionID: String,
        turnID: String? = nil,
        agentID: String,
        inputJSON: String,
        principal: ServicePrincipal
    ) {
        self.kind = kind
        self.sessionID = sessionID
        self.turnID = turnID
        self.agentID = agentID
        self.inputJSON = inputJSON
        self.principal = principal
    }
}

public struct WorkflowHandleDTO: Codable, Sendable, Hashable {
    public let workflowID: String
    public let kind: WorkflowKind
    public let status: WorkflowRunStatus
    public let deduplicated: Bool

    public init(workflowID: String, kind: WorkflowKind, status: WorkflowRunStatus, deduplicated: Bool) {
        self.workflowID = workflowID
        self.kind = kind
        self.status = status
        self.deduplicated = deduplicated
    }
}

public struct WorkflowEventDTO: Codable, Sendable, Hashable {
    public let seq: Int
    public let kind: String
    public let stage: String?
    public let message: String
    public let detailJSON: String?
    public let createdAt: String

    public init(
        seq: Int,
        kind: String,
        stage: String? = nil,
        message: String,
        detailJSON: String? = nil,
        createdAt: String
    ) {
        self.seq = seq
        self.kind = kind
        self.stage = stage
        self.message = message
        self.detailJSON = detailJSON
        self.createdAt = createdAt
    }
}

public struct WorkflowPollRequest: Codable, Sendable, Hashable {
    public let workflowID: String
    public let afterSeq: Int

    public init(workflowID: String, afterSeq: Int = 0) {
        self.workflowID = workflowID
        self.afterSeq = afterSeq
    }
}

public struct WorkflowPollResultDTO: Codable, Sendable, Hashable {
    public let workflowID: String
    public let status: WorkflowRunStatus
    public let events: [WorkflowEventDTO]
    public let resultJSON: String?
    public let errorMessage: String?

    public init(
        workflowID: String,
        status: WorkflowRunStatus,
        events: [WorkflowEventDTO],
        resultJSON: String? = nil,
        errorMessage: String? = nil
    ) {
        self.workflowID = workflowID
        self.status = status
        self.events = events
        self.resultJSON = resultJSON
        self.errorMessage = errorMessage
    }
}

public struct WorkflowCancelRequest: Codable, Sendable, Hashable {
    public let workflowID: String
    public let reason: String

    public init(workflowID: String, reason: String) {
        self.workflowID = workflowID
        self.reason = reason
    }
}
