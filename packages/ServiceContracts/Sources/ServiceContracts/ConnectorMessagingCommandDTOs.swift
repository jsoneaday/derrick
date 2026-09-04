import Foundation

public enum ConnectorOperationKind: String, Codable, Sendable, Hashable {
    case bootstrap
    case send
}

public enum ConnectorOperationStatus: String, Codable, Sendable, Hashable {
    case running
    case completed
    case failed
}

public struct ConnectorOperationRequest: Codable, Sendable, Hashable {
    public let operationID: String
    public let pluginID: String
    public let kind: ConnectorOperationKind
    public let vendorThreadID: String?
    public let threadID: String?
    public let text: String?

    public init(
        operationID: String,
        pluginID: String,
        kind: ConnectorOperationKind,
        vendorThreadID: String? = nil,
        threadID: String? = nil,
        text: String? = nil
    ) {
        self.operationID = operationID
        self.pluginID = pluginID
        self.kind = kind
        self.vendorThreadID = vendorThreadID
        self.threadID = threadID
        self.text = text
    }
}

public struct ConnectorOperationAckDTO: Codable, Sendable, Hashable {
    public let operationID: String
    public let accepted: Bool
    public let message: String

    public init(operationID: String, accepted: Bool, message: String) {
        self.operationID = operationID
        self.accepted = accepted
        self.message = message
    }
}

public struct ConnectorOperationPollRequest: Codable, Sendable, Hashable {
    public let operationID: String

    public init(operationID: String) {
        self.operationID = operationID
    }
}

public struct ConnectorOperationPollResult: Codable, Sendable, Hashable {
    public let operationID: String
    public let status: ConnectorOperationStatus
    public let error: String?

    public init(operationID: String, status: ConnectorOperationStatus, error: String? = nil) {
        self.operationID = operationID
        self.status = status
        self.error = error
    }
}
