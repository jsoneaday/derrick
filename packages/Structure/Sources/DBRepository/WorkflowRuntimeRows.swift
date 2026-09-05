import CryptoKit
import Foundation

public struct WorkflowRunRow: Sendable, Hashable {
    public let id: String
    public var kind: String
    public var status: String
    public let contextJSON: String
    public let inputJSON: String
    public let idempotencyKey: String?
    public var currentStepID: String?
    public var resultJSON: String?
    public var errorMessage: String?
    public let createdAt: Date
    public var finishedAt: Date?

    public init(
        id: String,
        kind: String,
        status: String,
        contextJSON: String,
        inputJSON: String,
        idempotencyKey: String?,
        currentStepID: String? = nil,
        resultJSON: String? = nil,
        errorMessage: String? = nil,
        createdAt: Date,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.contextJSON = contextJSON
        self.inputJSON = inputJSON
        self.idempotencyKey = idempotencyKey
        self.currentStepID = currentStepID
        self.resultJSON = resultJSON
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.finishedAt = finishedAt
    }
}

public struct WorkflowEventRow: Sendable, Hashable {
    public let seq: Int
    public let kind: String
    public let stage: String?
    public let message: String
    public let detailJSON: String?
    public let createdAt: Date

    public init(
        seq: Int,
        kind: String,
        stage: String?,
        message: String,
        detailJSON: String?,
        createdAt: Date
    ) {
        self.seq = seq
        self.kind = kind
        self.stage = stage
        self.message = message
        self.detailJSON = detailJSON
        self.createdAt = createdAt
    }
}

public struct ToolRunRow: Sendable, Hashable {
    public let id: String
    public let toolName: String
    public let argumentsJSON: String
    public let principalJSON: String
    public let contextJSON: String
    public var status: String
    public var resultText: String?
    public var isError: Bool
    public var errorMessage: String?
    public let createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(
        id: String,
        toolName: String,
        argumentsJSON: String,
        principalJSON: String,
        contextJSON: String,
        status: String,
        resultText: String?,
        isError: Bool,
        errorMessage: String?,
        createdAt: Date,
        startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.principalJSON = principalJSON
        self.contextJSON = contextJSON
        self.status = status
        self.resultText = resultText
        self.isError = isError
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public enum WorkflowRuntimeIdempotency {
    public static func key(sessionID: String, kind: WorkflowKind, inputJSON: String) -> String {
        let material = "\(sessionID)|\(kind.rawValue)|\(inputJSON)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
