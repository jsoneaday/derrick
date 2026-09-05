import AgentRuntime
import Foundation
import PolicyUserInteraction
import Structure

/// Per-turn + execution-context slots for AgentService-hosted turns (API keys, network prompts).
///
/// `TaskLocal` alone is not enough: MCP tool handlers often run on unstructured tasks
/// that do not inherit task-locals. Registry slots keyed by `ExecutionContextID` cover that;
/// TaskLocal still preferred when present.
public enum TurnProcessContext {
    public typealias NetworkPrompt = TurnProcessContextTypes.NetworkPrompt
    public typealias PolicyDecisionPrompt = TurnProcessContextTypes.PolicyDecisionPrompt
    public typealias PolicyNoticePublisher = TurnProcessContextTypes.PolicyNoticePublisher

    /// Active execution context for the current turn (preferred over process-wide lookup).
    @TaskLocal public static var executionContextID: ExecutionContextID?

    /// Conversation API key from the UI turn request (AgentService has no app keychain).
    @TaskLocal public static var conversationAPIKey: String?

    /// Optional reverse-XPC network access prompt (host, toolName) → decision.
    @TaskLocal public static var networkAccessPrompt: NetworkPrompt?

    /// Optional reverse-XPC for usage limits / content sensitivity (PolicyUserEvent → decision).
    @TaskLocal public static var policyDecisionPrompt: PolicyDecisionPrompt?

    /// Fire-and-forget policy notices (failure / informational modals) when UI is connected.
    @TaskLocal public static var policyNoticePublisher: PolicyNoticePublisher?

    /// Active `/create-plugin` or `/edit-plugin` factory turn (enables sync `web.crawl`).
    @TaskLocal public static var pluginFactoryCreationActive: Bool = false

    public static func install(
        for contextID: ExecutionContextID,
        apiKey: String?,
        networkAccessPrompt: NetworkPrompt?,
        policyDecisionPrompt: PolicyDecisionPrompt? = nil,
        policyNoticePublisher: PolicyNoticePublisher? = nil,
        pluginFactoryCreationActive: Bool = false
    ) {
        ExecutionContextRegistry.shared.install(
            contextID,
            slots: ExecutionContextSlots(
                apiKey: apiKey,
                networkAccessPrompt: networkAccessPrompt,
                policyDecisionPrompt: policyDecisionPrompt,
                policyNoticePublisher: policyNoticePublisher,
                pluginFactoryCreationActive: pluginFactoryCreationActive
            )
        )
    }

    public static func clear(contextID: ExecutionContextID) {
        ExecutionContextRegistry.shared.remove(contextID)
    }

    private static func resolvedRegistrySlots() -> ExecutionContextSlots? {
        if let id = executionContextID,
           let slots = ExecutionContextRegistry.shared.slots(for: id) {
            return slots
        }
        if let caller = AgentCallContext.caller,
           let slots = ExecutionContextRegistry.shared.resolve(contextID: nil, caller: caller) {
            return slots
        }
        return ExecutionContextRegistry.shared.slotsWhenUnambiguous()
    }

    public static var effectiveAPIKey: String? {
        if let key = conversationAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return key
        }
        let trimmed = resolvedRegistrySlots()?.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    public static var effectiveNetworkAccessPrompt: NetworkPrompt? {
        if let prompt = networkAccessPrompt {
            return prompt
        }
        return resolvedRegistrySlots()?.networkAccessPrompt
    }

    public static var effectivePolicyDecisionPrompt: PolicyDecisionPrompt? {
        if let prompt = policyDecisionPrompt {
            return prompt
        }
        return resolvedRegistrySlots()?.policyDecisionPrompt
    }

    public static var effectivePolicyNoticePublisher: PolicyNoticePublisher? {
        if let publisher = policyNoticePublisher {
            return publisher
        }
        return resolvedRegistrySlots()?.policyNoticePublisher
    }

    public static var effectivePluginFactoryCreationActive: Bool {
        if pluginFactoryCreationActive {
            return true
        }
        return resolvedRegistrySlots()?.pluginFactoryCreationActive == true
    }
}
