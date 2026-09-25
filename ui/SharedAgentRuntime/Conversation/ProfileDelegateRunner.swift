import Foundation
import MCP
import AgentRuntime
import DBRepository
import LLMAgentClient
import MCPClient
import MemorySystem
import PolicyRuntime
import Structure

/// Caps how many delegated profiles one caller may have in flight.
actor ProfileSubagentGate {
    static let shared = ProfileSubagentGate()
    private var inFlight: [String: Int] = [:]

    func begin(caller: String, limit: Int) throws {
        let current = inFlight[caller, default: 0]
        guard current < limit else {
            throw ProfileDelegateRunnerError.tooManySubagents(limit)
        }
        inFlight[caller] = current + 1
    }

    func end(caller: String) {
        let next = (inFlight[caller] ?? 1) - 1
        if next <= 0 {
            inFlight[caller] = nil
        } else {
            inFlight[caller] = next
        }
    }
}

/// Runs a collected sub-turn as a delegated agent profile.
enum ProfileDelegateRunner {
    nonisolated static func run(
        profileHandle: String,
        task: String,
        sessionKey: MemorySessionKey,
        memoryCoordinator: MemoryCoordinator,
        policyStore: (any PolicyStore)?,
        repository: DBRepository,
        agentsClient: MCPClient,
        ragInstructions: String,
        mcpToolInstructions: String,
        responseSchema: AgentSchema,
        interceptor: PolicyInterceptor
    ) async throws -> String {
        let normalized = AgentProfileHandle.normalize(
            profileHandle.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "$", with: "")
        ) ?? profileHandle.lowercased()
        guard let profile = try await repository.agentProfile(handle: normalized), profile.isEnabled else {
            throw ProfileDelegateRunnerError.profileUnavailable(normalized)
        }
        guard profile.capabilities.allowsSubagent else {
            throw ProfileDelegateRunnerError.invalidTarget(normalized)
        }

        let profileContext = AgentProfileTurnContext(profile: profile)
        let model = (try? JSONDecoder().decode(LLMModelChoice.self, from: profileContext.modelJSON))
            ?? .defaultHelperModel
        let thinking = profileContext.thinkingJSON.flatMap {
            try? JSONDecoder().decode(ModelThinkingOption.self, from: $0)
        }
        let apiKey = await LLMProviderCredentialGate.resolveAPIKey(for: model) ?? ""

        let delegateSessionKey = MemorySessionKey(
            sessionID: sessionKey.sessionID,
            agentID: "profile-\(normalized)"
        )
        let userRagBase = [
            profileContext.rag.useDefaultInstructions
                ? ragInstructions
                : profileContext.rag.customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? profileContext.rag.customInstructions!
                    : ragInstructions,
            profileContext.instructions.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
        let retrievalLimit = profileContext.rag.useSessionMemory ? profileContext.rag.retrievalLimit : 0

        let delegateToolClient = XPCConversationToolClient(
            principal: ServicePrincipal.agent(
                sessionID: sessionKey.sessionID,
                agentID: delegateSessionKey.agentID
            ),
            agentsClient: agentsClient,
            helperReviewerModelJSONProvider: { nil }
        )

        let subagentCapabilities = AgentProfileCapabilities(allowsSubagent: true, allowedSubagentHandles: [])
        let completeText = try await TurnProcessContext.$activeProfileCapabilities.withValue(subagentCapabilities) {
            let stream = await ConversationModel.makePolicyStream(
                prompt: task,
                apiKey: apiKey,
                model: model,
                thinking: thinking,
                sessionKey: delegateSessionKey,
                memoryCoordinator: memoryCoordinator,
                policyStore: policyStore,
                mcpClient: delegateToolClient,
                ragInstructions: userRagBase,
                mcpToolInstructions: mcpToolInstructions,
                responseSchema: responseSchema,
                interceptor: interceptor,
                approvalPresenter: nil,
                retrievalLimit: retrievalLimit
            )
            var text = ""
            for try await chunk in stream {
                if chunk.status == .complete {
                    text += chunk.chunk ?? ""
                }
            }
            return text
        }
        let trimmed = completeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProfileDelegateRunnerError.emptyResponse
        }
        return trimmed
    }
}

enum ProfileDelegateRunnerError: Error, LocalizedError {
    case invalidTarget(String)
    case profileUnavailable(String)
    case tooManySubagents(Int)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidTarget(let handle):
            return "Profile \(handle) cannot be delegated to. It is not allowed to act as a subagent."
        case .profileUnavailable(let handle):
            return "Profile \(handle) is not available."
        case .tooManySubagents(let limit):
            return "This profile can run at most \(limit) subagents at once."
        case .emptyResponse:
            return "Delegated profile produced no response."
        }
    }
}
