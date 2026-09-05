import Foundation

/// Turn-scoped callback types shared across execution contexts and the UI reverse-XPC bridge.
public enum TurnProcessContextTypes {
    public typealias NetworkPrompt = @Sendable (_ host: String, _ toolName: String) async -> PolicyUserDecision
    public typealias PolicyDecisionPrompt = @Sendable (_ event: PolicyUserEvent) async -> PolicyUserDecision
    public typealias PolicyNoticePublisher = @Sendable (_ event: PolicyUserEvent) async -> Void
}

/// Per-execution-context turn slots (API key, HITL hooks).
public struct ExecutionContextSlots: Sendable {
    public var apiKey: String?
    public var networkAccessPrompt: TurnProcessContextTypes.NetworkPrompt?
    public var policyDecisionPrompt: TurnProcessContextTypes.PolicyDecisionPrompt?
    public var policyNoticePublisher: TurnProcessContextTypes.PolicyNoticePublisher?
    /// When true, `web.crawl` may run synchronously (plugin factory turns).
    public var pluginFactoryCreationActive: Bool

    public init(
        apiKey: String? = nil,
        networkAccessPrompt: TurnProcessContextTypes.NetworkPrompt? = nil,
        policyDecisionPrompt: TurnProcessContextTypes.PolicyDecisionPrompt? = nil,
        policyNoticePublisher: TurnProcessContextTypes.PolicyNoticePublisher? = nil,
        pluginFactoryCreationActive: Bool = false
    ) {
        self.apiKey = apiKey
        self.networkAccessPrompt = networkAccessPrompt
        self.policyDecisionPrompt = policyDecisionPrompt
        self.policyNoticePublisher = policyNoticePublisher
        self.pluginFactoryCreationActive = pluginFactoryCreationActive
    }
}
