import DBRepository
import DerrickBackend
import Foundation
import LLMAgentClient
import Structure

enum MessagingAgentTurnClient {
    static func handle(route: MessagingAgentRoute) async throws {
        let repository = try await JobServiceStore.shared.sharedRepository()
        try await ensureBuiltins(repository: repository)
        let profile = try await resolveProfile(handle: route.profileHandle, repository: repository)
        let model = (try? JSONDecoder().decode(LLMModelChoice.self, from: profile.modelJSON))
            ?? .defaultHelperModel
        let apiKey = await resolveAPIKey(for: model) ?? ""
        let profileContextJSON = try JSONEncoder().encode(AgentProfileTurnContext(profile: profile))
        let sessionID = MessagingAgentSessionID.make(
            pluginID: route.pluginID,
            threadID: route.threadID,
            profileHandle: profile.handle
        )
        let request = AgentTurnRequest(
            turnID: UUID().uuidString,
            sessionID: sessionID,
            prompt: route.prompt,
            apiKey: apiKey,
            modelJSON: profile.modelJSON,
            thinkingJSON: profile.thinkingJSON,
            profileContextJSON: profileContextJSON
        )
        let response = try await AgentServiceTurnHost.shared.runCollectedTurn(request: request)
        let outbound = MessagingAgentOutboundFormatter.formatReply(response, profileHandle: profile.handle)
        try await sendConnectorMessage(
            route: route,
            text: outbound,
            repository: repository
        )
        fputs(
            "[MessagingAgentTurnClient] relayed pluginID=\(route.pluginID) profile=\(profile.handle) chars=\(outbound.count)\n",
            stderr
        )
    }

    private static func ensureBuiltins(repository: DBRepository) async throws {
        for profile in try AgentProfileBuiltinFactory.all() {
            try await repository.upsertAgentProfile(profile)
        }
    }

    private static func resolveProfile(
        handle: String,
        repository: DBRepository
    ) async throws -> AgentProfile {
        if let profile = try await repository.agentProfile(handle: handle), profile.isEnabled {
            return profile
        }
        if let orchestrator = try await repository.agentProfile(handle: AgentProfileHandle.orchestrator),
           orchestrator.isEnabled {
            return orchestrator
        }
        throw MessagingAgentTurnClientError.profileUnavailable(handle)
    }

    @MainActor
    private static func resolveAPIKey(for model: LLMModelChoice) -> String? {
        AppSecretResolver().resolve(
            account: model.provider.secretAccount,
            environmentKeys: model.provider.apiKeyEnvironmentKeys
        )
    }

    private static func sendConnectorMessage(
        route: MessagingAgentRoute,
        text: String,
        repository: DBRepository
    ) async throws {
        let request = ConnectorOperationRequest(
            operationID: UUID().uuidString,
            pluginID: route.pluginID,
            kind: .send,
            vendorThreadID: route.vendorThreadID,
            threadID: route.threadID,
            text: text,
            parentVendorMessageID: route.parentVendorMessageID
        )
        let ack = try await ConnectorMessagingCommandService.shared.submit(request) {
            repository
        }
        guard ack.accepted else {
            throw MessagingAgentTurnClientError.sendRejected(ack.message)
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + 120_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let poll = try await ConnectorMessagingCommandService.shared.poll(
                ConnectorOperationPollRequest(operationID: request.operationID)
            )
            switch poll.status {
            case .running:
                try await Task.sleep(nanoseconds: 300_000_000)
            case .completed:
                return
            case .failed:
                throw MessagingAgentTurnClientError.sendFailed(poll.error ?? "Connector send failed.")
            }
        }
        throw MessagingAgentTurnClientError.sendTimedOut
    }
}

enum MessagingAgentTurnClientError: Error, LocalizedError {
    case profileUnavailable(String)
    case sendRejected(String)
    case sendFailed(String)
    case sendTimedOut

    var errorDescription: String? {
        switch self {
        case .profileUnavailable(let handle):
            return "No enabled agent profile found for $\(handle)."
        case .sendRejected(let message):
            return message
        case .sendFailed(let message):
            return message
        case .sendTimedOut:
            return "Connector send timed out."
        }
    }
}
