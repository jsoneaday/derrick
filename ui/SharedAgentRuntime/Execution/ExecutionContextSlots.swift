import Foundation
import PolicyUserInteraction

/// Per-execution-context turn slots (API key, HITL hooks).
public struct ExecutionContextSlots: Sendable {
    public var apiKey: String?
    public var networkAccessPrompt: TurnProcessContext.NetworkPrompt?
    public var policyDecisionPrompt: TurnProcessContext.PolicyDecisionPrompt?
    public var policyNoticePublisher: TurnProcessContext.PolicyNoticePublisher?
    /// When true, `web.crawl` may run synchronously (plugin factory turns).
    public var pluginFactoryCreationActive: Bool

    public init(
        apiKey: String? = nil,
        networkAccessPrompt: TurnProcessContext.NetworkPrompt? = nil,
        policyDecisionPrompt: TurnProcessContext.PolicyDecisionPrompt? = nil,
        policyNoticePublisher: TurnProcessContext.PolicyNoticePublisher? = nil,
        pluginFactoryCreationActive: Bool = false
    ) {
        self.apiKey = apiKey
        self.networkAccessPrompt = networkAccessPrompt
        self.policyDecisionPrompt = policyDecisionPrompt
        self.policyNoticePublisher = policyNoticePublisher
        self.pluginFactoryCreationActive = pluginFactoryCreationActive
    }
}
