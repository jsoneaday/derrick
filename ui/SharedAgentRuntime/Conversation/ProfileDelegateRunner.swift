import Foundation
import MCP
import AgentRuntime
import DBRepository
import LLMAgentClient
import MCPClient
import MCPServer
import MemorySystem
import PolicyRuntime
import Structure

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
        guard AgentProfileHandle.delegateTargets.contains(normalized) else {
            throw ProfileDelegateRunnerError.invalidTarget(normalized)
        }
        guard let profile = try await repository.agentProfile(handle: normalized), profile.isEnabled else {
            throw ProfileDelegateRunnerError.profileUnavailable(normalized)
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

        var completeText = ""
        for try await chunk in stream {
            if chunk.status == .complete {
                completeText += chunk.chunk ?? ""
            }
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
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidTarget(let handle):
            return "Profile \(handle) cannot be delegated to. Use developer, researcher, or general."
        case .profileUnavailable(let handle):
            return "Profile \(handle) is not available."
        case .emptyResponse:
            return "Delegated profile produced no response."
        }
    }
}
