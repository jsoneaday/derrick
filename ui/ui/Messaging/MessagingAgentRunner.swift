import DBRepository
import Foundation
import LLMAgentClient
import Structure

enum MessagingAgentRunner {
    @MainActor
    static func runAndRelay(
        prompt: String,
        profile: AgentProfile,
        pluginID: String,
        thread: MessagingThreadDTO,
        parentVendorMessageID: String?,
        connectorRuntime: ConnectorMessagingRuntime,
        repository: DBRepository,
        store: MessagingStore,
        session: MessagingSessionStore
    ) async throws {
        let sessionID = MessagingAgentSessionID.make(
            pluginID: pluginID,
            threadID: thread.id,
            profileHandle: profile.handle
        )
        let model = (try? JSONDecoder().decode(LLMModelChoice.self, from: profile.modelJSON))
            ?? .defaultHelperModel
        let apiKey = resolveAPIKey(for: model) ?? ""
        let profileContextJSON = try JSONEncoder().encode(AgentProfileTurnContext(profile: profile))
        let modelJSON = try JSONEncoder().encode(model)

        try await AgentServiceClient.shared.ensureReadyForTurn()
        let request = AgentTurnRequest(
            sessionID: sessionID,
            prompt: prompt,
            apiKey: apiKey,
            modelJSON: modelJSON,
            thinkingJSON: profile.thinkingJSON,
            profileContextJSON: profileContextJSON
        )

        var response = ""
        let stream = AgentServiceClient.shared.streamTurn(request)
        let streamStarted = Date()
        let streamTimeoutSeconds: TimeInterval = 300
        for try await dto in stream {
            if Date().timeIntervalSince(streamStarted) > streamTimeoutSeconds {
                throw AgentServiceClientError.timeout
            }
            if dto.status == AgentResponseStatus.complete.rawValue,
               let chunk = dto.chunk,
               !chunk.isEmpty {
                response += chunk
            }
        }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MessagingAgentRunnerError.emptyResponse
        }

        let outbound = MessagingAgentOutboundFormatter.formatReply(trimmed)
        try await connectorRuntime.send(
            pluginID: pluginID,
            text: outbound,
            thread: thread,
            parentVendorMessageID: parentVendorMessageID,
            repository: repository,
            store: store,
            session: session
        )
    }

    @MainActor
    private static func resolveAPIKey(for model: LLMModelChoice) -> String? {
        AppSecretResolver().resolve(
            account: model.provider.secretAccount,
            environmentKeys: model.provider.apiKeyEnvironmentKeys
        )
    }
}

enum MessagingAgentRunnerError: Error, LocalizedError {
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "The agent did not return a response."
        }
    }
}
