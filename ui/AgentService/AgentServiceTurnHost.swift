import Foundation
import DBRepository
import LLMAgentClient
import PolicyUserInteraction
import ServiceContracts

private final class ChunkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
    @discardableResult
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }
}

/// Hosts `ConversationModel` sessions and streams turn chunks to the UI sink.
actor AgentServiceTurnHost {
    static let shared = AgentServiceTurnHost()

    private var conversation: ConversationModel?
    private var repository: DBRepository?
    private var helperModelSettings: LLMModelSettings?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var sessionID: String?

    func ensureConversation(applicationName: String) async throws -> ConversationModel {
        if let conversation {
            return conversation
        }
        let repo = try await AgentServiceStore.shared.sharedRepository()
        repository = repo
        let settings = await MainActor.run {
            LLMModelSettings(repository: repo)
        }
        await settings.loadSettings()
        helperModelSettings = settings
        await EgressAllowlistService.shared.configure(repository: repo)
        await ContentSensitivityGrantService.shared.configure(repository: repo)
        await UsageLimitsService.shared.configure(repository: repo)
        await EgressAllowlistService.shared.pushToHelper()

        let model = try await ConversationModel.makeDefault(
            repository: repo,
            helperModelSettings: settings
        )
        conversation = model
        sessionID = model.sessionKey.sessionID
        await AgentServiceStore.shared.log(
            level: .info,
            message: "Turn host session ready session=\(model.sessionKey.sessionID)",
            code: "turn_host_ready"
        )
        return model
    }

    func startTurn(
        request: AgentTurnRequest,
        connectionContext: AgentServiceConnectionContext
    ) async -> AgentTurnAccepted {
        do {
            let model = try await ensureConversation(applicationName: request.applicationName)
            let llmModel = try JSONDecoder().decode(LLMModelChoice.self, from: request.modelJSON)
            let turnID = request.turnID
            let sid = sessionID ?? model.sessionKey.sessionID
            let prompt = request.prompt
            let apiKey = request.apiKey
            let apiKeyEmpty = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            tasks[turnID]?.cancel()
            tasks[turnID] = Task {
                await self.executeTurn(
                    turnID: turnID,
                    conversation: model,
                    prompt: prompt,
                    apiKey: apiKey,
                    model: llmModel,
                    connectionContext: connectionContext
                )
            }

            await AgentServiceStore.shared.log(
                level: .info,
                message: "startTurn accepted id=\(turnID) model=\(llmModel.id) apiKeyEmpty=\(apiKeyEmpty)",
                code: "start_turn_accepted"
            )

            return AgentTurnAccepted(
                ok: true,
                turnID: turnID,
                sessionID: sid,
                message: "started"
            )
        } catch {
            let message = error.localizedDescription
            await AgentServiceStore.shared.log(
                level: .error,
                message: "startTurn failed: \(message)",
                code: "start_turn_failed"
            )
            return AgentTurnAccepted(
                ok: false,
                turnID: request.turnID,
                sessionID: sessionID ?? "",
                message: message
            )
        }
    }

    func cancelTurn(turnID: String) {
        tasks[turnID]?.cancel()
        tasks[turnID] = nil
    }

    private func executeTurn(
        turnID: String,
        conversation: ConversationModel,
        prompt: String,
        apiKey: String,
        model: LLMModelChoice,
        connectionContext: AgentServiceConnectionContext
    ) async {
        await AgentServiceStore.shared.log(
            level: .info,
            message: "turn started id=\(turnID) chars=\(prompt.count)",
            code: "turn_start"
        )
        let counter = ChunkCounter()
        let approvalPresenter = XPCRemoteApprovalPresenter(turnID: turnID) {
            connectionContext.clientSink(logLabel: "approval")
        }
        let networkPrompt: @Sendable (String, String) async -> PolicyUserInteraction.PolicyUserDecision = { host, toolName in
            await XPCRemoteNetworkAccess.prompt(
                host: host,
                toolName: toolName,
                resolveSink: { connectionContext.clientSink(logLabel: "network") }
            )
        }
        // Process-wide slots: MCP tool tasks do not inherit TaskLocal from the turn task.
        TurnProcessContext.installProcessTurnContext(apiKey: apiKey, networkAccessPrompt: networkPrompt)
        defer { TurnProcessContext.clearProcessTurnContext() }
        do {
            try await TurnProcessContext.$conversationAPIKey.withValue(apiKey) {
                try await TurnProcessContext.$networkAccessPrompt.withValue(networkPrompt) {
                    try await conversation.runTurn(
                        prompt: prompt,
                        apiKey: apiKey,
                        model: model,
                        approvalPresenter: approvalPresenter
                    ) { chunk in
                        let n = counter.increment()
                        let dto = AgentTurnChunkDTO(
                            turnID: turnID,
                            status: chunk.status.rawValue,
                            chunk: chunk.chunk,
                            toolName: chunk.toolName
                        )
                        guard let data = try? AgentServiceXPCCodec.encodeTurnChunk(dto) else {
                            fputs("[AgentService] failed to encode chunk for \(turnID)\n", stderr)
                            return
                        }
                        let delivered = Self.deliverChunk(
                            turnID: turnID,
                            data: data as NSData,
                            connectionContext: connectionContext
                        )
                        if !delivered {
                            fputs("[AgentService] drop chunk #\(n) (nil sink) turn=\(turnID)\n", stderr)
                        }
                    }
                }
            }

            let chunkCount = counter.value
            if Task.isCancelled {
                let err = AgentTurnErrorDTO(turnID: turnID, message: "cancelled", code: "cancelled")
                let data = (try? AgentServiceXPCCodec.encodeTurnError(err)) ?? Data()
                Self.deliverFinish(turnID: turnID, errorJSON: data as NSData, connectionContext: connectionContext)
            } else if chunkCount == 0 {
                // Surface empty pipeline as an error so the UI does not hang on a blank bubble.
                let err = AgentTurnErrorDTO(
                    turnID: turnID,
                    message: "AgentService turn completed with no response chunks (empty model stream or pipeline early exit).",
                    code: "empty_stream"
                )
                let data = (try? AgentServiceXPCCodec.encodeTurnError(err)) ?? Data()
                Self.deliverFinish(turnID: turnID, errorJSON: data as NSData, connectionContext: connectionContext)
            } else {
                Self.deliverFinish(turnID: turnID, errorJSON: Data() as NSData, connectionContext: connectionContext)
            }
            await AgentServiceStore.shared.log(
                level: chunkCount == 0 ? .error : .info,
                message: "turn finished id=\(turnID) cancelled=\(Task.isCancelled) chunks=\(chunkCount)",
                code: "turn_finish"
            )
        } catch {
            let message = error.localizedDescription
            await AgentServiceStore.shared.log(
                level: .error,
                message: "turn failed id=\(turnID): \(message)",
                code: "turn_failed"
            )
            let err = AgentTurnErrorDTO(turnID: turnID, message: message, code: "stream_error")
            let data = (try? AgentServiceXPCCodec.encodeTurnError(err)) ?? Data()
            let delivered = Self.deliverFinish(
                turnID: turnID,
                errorJSON: data as NSData,
                connectionContext: connectionContext
            )
            if !delivered {
                fputs("[AgentService] drop finish-error (nil sink) turn=\(turnID)\n", stderr)
            }
        }
        tasks[turnID] = nil
    }

    /// Deliver to the initiating connection sink. Also to primary UI only when the initiator is
    /// *not* the UI (job peer wakes). Never double-send to the same UI connection.
    @discardableResult
    private static func deliverChunk(
        turnID: String,
        data: NSData,
        connectionContext: AgentServiceConnectionContext
    ) -> Bool {
        var delivered = false
        if let sink = connectionContext.clientSink(logLabel: "chunk") {
            sink.turnDidEmitChunk(turnID, chunkJSON: data)
            delivered = true
        }
        let initiatorIsUI = AgentServicePrimaryUISink.shared.isPrimaryConnection(
            connectionContext.attachedConnection()
        )
        if !initiatorIsUI, let ui = AgentServicePrimaryUISink.shared.clientSink(logLabel: "chunk-ui") {
            ui.turnDidEmitChunk(turnID, chunkJSON: data)
            delivered = true
        }
        return delivered
    }

    @discardableResult
    private static func deliverFinish(
        turnID: String,
        errorJSON: NSData,
        connectionContext: AgentServiceConnectionContext
    ) -> Bool {
        var delivered = false
        if let sink = connectionContext.clientSink(logLabel: "finish") {
            sink.turnDidFinish(turnID, errorJSON: errorJSON)
            delivered = true
        }
        let initiatorIsUI = AgentServicePrimaryUISink.shared.isPrimaryConnection(
            connectionContext.attachedConnection()
        )
        if !initiatorIsUI, let ui = AgentServicePrimaryUISink.shared.clientSink(logLabel: "finish-ui") {
            ui.turnDidFinish(turnID, errorJSON: errorJSON)
            delivered = true
        }
        return delivered
    }
}
