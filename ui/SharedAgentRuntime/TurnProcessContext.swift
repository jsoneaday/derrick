import Foundation
import PolicyUserInteraction

/// Per-turn + process context for AgentService-hosted turns (API keys, network prompts).
///
/// `TaskLocal` alone is not enough: MCP tool handlers often run on unstructured tasks
/// that do not inherit task-locals. Process-wide slots cover that; TaskLocal still
/// preferred when present.
public enum TurnProcessContext {
    public typealias NetworkPrompt = @Sendable (_ host: String, _ toolName: String) async -> PolicyUserDecision
    public typealias JobSchedulingPreflight = @Sendable (_ toolName: String, _ toolArgumentsJSON: String) async throws -> Void
    public typealias PolicyDecisionPrompt = @Sendable (_ event: PolicyUserEvent) async -> PolicyUserDecision
    public typealias PolicyNoticePublisher = @Sendable (_ event: PolicyUserEvent) async -> Void

    /// Conversation API key from the UI turn request (AgentService has no app keychain).
    @TaskLocal public static var conversationAPIKey: String?

    /// Optional reverse-XPC network access prompt (host, toolName) → decision.
    @TaskLocal public static var networkAccessPrompt: NetworkPrompt?

    @TaskLocal public static var jobSchedulingPreflight: JobSchedulingPreflight?

    /// Optional reverse-XPC for usage limits / content sensitivity (PolicyUserEvent → decision).
    @TaskLocal public static var policyDecisionPrompt: PolicyDecisionPrompt?

    /// Fire-and-forget policy notices (failure / informational modals) when UI is connected.
    @TaskLocal public static var policyNoticePublisher: PolicyNoticePublisher?

    public static func installProcessTurnContext(
        apiKey: String?,
        networkAccessPrompt: NetworkPrompt?,
        jobSchedulingPreflight: JobSchedulingPreflight? = nil,
        policyDecisionPrompt: PolicyDecisionPrompt? = nil,
        policyNoticePublisher: PolicyNoticePublisher? = nil
    ) {
        ProcessTurnSlots.shared.install(
            apiKey: apiKey,
            networkAccessPrompt: networkAccessPrompt,
            jobSchedulingPreflight: jobSchedulingPreflight,
            policyDecisionPrompt: policyDecisionPrompt,
            policyNoticePublisher: policyNoticePublisher
        )
    }

    public static func clearProcessTurnContext() {
        ProcessTurnSlots.shared.clear()
    }

    public static var effectiveAPIKey: String? {
        if let key = conversationAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return key
        }
        return ProcessTurnSlots.shared.apiKey
    }

    public static var effectiveNetworkAccessPrompt: NetworkPrompt? {
        if let prompt = networkAccessPrompt {
            return prompt
        }
        return ProcessTurnSlots.shared.networkAccessPrompt
    }

    public static var effectiveJobSchedulingPreflight: JobSchedulingPreflight? {
        if let hook = jobSchedulingPreflight {
            return hook
        }
        return ProcessTurnSlots.shared.jobSchedulingPreflight
    }

    public static var effectivePolicyDecisionPrompt: PolicyDecisionPrompt? {
        if let prompt = policyDecisionPrompt {
            return prompt
        }
        return ProcessTurnSlots.shared.policyDecisionPrompt
    }

    public static var effectivePolicyNoticePublisher: PolicyNoticePublisher? {
        if let publisher = policyNoticePublisher {
            return publisher
        }
        return ProcessTurnSlots.shared.policyNoticePublisher
    }
}

/// Thread-safe process-wide turn slots (MCP tool tasks do not inherit TaskLocal).
private final class ProcessTurnSlots: @unchecked Sendable {
    static let shared = ProcessTurnSlots()

    private let lock = NSLock()
    private var storedAPIKey: String?
    private var storedNetworkPrompt: TurnProcessContext.NetworkPrompt?
    private var storedJobSchedulingPreflight: TurnProcessContext.JobSchedulingPreflight?
    private var storedPolicyDecisionPrompt: TurnProcessContext.PolicyDecisionPrompt?
    private var storedPolicyNoticePublisher: TurnProcessContext.PolicyNoticePublisher?

    private init() {}

    func install(
        apiKey: String?,
        networkAccessPrompt: TurnProcessContext.NetworkPrompt?,
        jobSchedulingPreflight: TurnProcessContext.JobSchedulingPreflight?,
        policyDecisionPrompt: TurnProcessContext.PolicyDecisionPrompt?,
        policyNoticePublisher: TurnProcessContext.PolicyNoticePublisher?
    ) {
        lock.lock()
        storedAPIKey = apiKey
        storedNetworkPrompt = networkAccessPrompt
        storedJobSchedulingPreflight = jobSchedulingPreflight
        storedPolicyDecisionPrompt = policyDecisionPrompt
        storedPolicyNoticePublisher = policyNoticePublisher
        lock.unlock()
    }

    func clear() {
        lock.lock()
        storedAPIKey = nil
        storedNetworkPrompt = nil
        storedJobSchedulingPreflight = nil
        storedPolicyDecisionPrompt = nil
        storedPolicyNoticePublisher = nil
        lock.unlock()
    }

    var apiKey: String? {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = storedAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    var networkAccessPrompt: TurnProcessContext.NetworkPrompt? {
        lock.lock()
        defer { lock.unlock() }
        return storedNetworkPrompt
    }

    var jobSchedulingPreflight: TurnProcessContext.JobSchedulingPreflight? {
        lock.lock()
        defer { lock.unlock() }
        return storedJobSchedulingPreflight
    }

    var policyDecisionPrompt: TurnProcessContext.PolicyDecisionPrompt? {
        lock.lock()
        defer { lock.unlock() }
        return storedPolicyDecisionPrompt
    }

    var policyNoticePublisher: TurnProcessContext.PolicyNoticePublisher? {
        lock.lock()
        defer { lock.unlock() }
        return storedPolicyNoticePublisher
    }
}
