import Foundation

/// Generic policy UI decision request (usage limits, content sensitivity, etc.).
/// AgentService cannot use in-process `AppEventBus` — PolicyEventPresenter lives in the UI.
public struct AgentPolicyDecisionRequestDTO: Codable, Sendable, Hashable {
    public let requestID: String
    public let kind: String
    public let source: String
    public let title: String
    public let summary: String
    public let detail: String?
    public let toolName: String?
    public let payloadPreview: String?
    public let rememberKey: String?
    public let correlationId: String?

    public init(
        requestID: String = UUID().uuidString,
        kind: String,
        source: String,
        title: String,
        summary: String,
        detail: String? = nil,
        toolName: String? = nil,
        payloadPreview: String? = nil,
        rememberKey: String? = nil,
        correlationId: String? = nil
    ) {
        self.requestID = requestID
        self.kind = kind
        self.source = source
        self.title = title
        self.summary = summary
        self.detail = detail
        self.toolName = toolName
        self.payloadPreview = payloadPreview
        self.rememberKey = rememberKey
        self.correlationId = correlationId
    }
}

public struct AgentPolicyDecisionDTO: Codable, Sendable, Hashable {
    public let requestID: String
    /// One of: approved, approvedOnce, approvedPermanently, denied, dismissed, timedOut
    public let decision: String
    public let actor: String?

    public init(requestID: String, decision: String, actor: String? = nil) {
        self.requestID = requestID
        self.decision = decision
        self.actor = actor
    }
}
