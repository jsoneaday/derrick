import Foundation
import PolicyUserInteraction

/// Per-execution-context turn slots (API key, HITL hooks).
public struct ExecutionContextSlots: Sendable {
    public var apiKey: String?
    public var networkAccessPrompt: TurnProcessContext.NetworkPrompt?
    public var policyDecisionPrompt: TurnProcessContext.PolicyDecisionPrompt?
    public var policyNoticePublisher: TurnProcessContext.PolicyNoticePublisher?

    public init(
        apiKey: String? = nil,
        networkAccessPrompt: TurnProcessContext.NetworkPrompt? = nil,
        policyDecisionPrompt: TurnProcessContext.PolicyDecisionPrompt? = nil,
        policyNoticePublisher: TurnProcessContext.PolicyNoticePublisher? = nil
    ) {
        self.apiKey = apiKey
        self.networkAccessPrompt = networkAccessPrompt
        self.policyDecisionPrompt = policyDecisionPrompt
        self.policyNoticePublisher = policyNoticePublisher
    }
}
