import Foundation
import DBRepository
import LLMAgentClient
import PolicyUserInteraction
import ServiceContracts

private enum AgentServiceError: Error, LocalizedError {
    case notReady
    var errorDescription: String? {
        switch self {
        case .notReady: return "AgentService runtime not ready."
        }
    }
}

private final class ResponseAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [String] = []
    func append(_ s: String) {
        lock.lock()
        parts.append(s)
        lock.unlock()
    }
    var joined: String {
        lock.lock()
        defer { lock.unlock() }
        return parts.joined()
    }
}

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

    /// Live chat conversation (single primary UI session).
    private var conversation: ConversationModel?
    /// Isolated job wake conversations keyed by job session id (`job-…`).
    private var jobConversations: [String: ConversationModel] = [:]
    private var repository: DBRepository?
    private var helperModelSettings: LLMModelSettings?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var sessionID: String?

    func ensureConversation(applicationName: String) async throws -> ConversationModel {
        if let conversation {
            return conversation
        }
        try await ensureRuntimeReady()
        guard let repo = repository, let settings = helperModelSettings else {
            throw AgentServiceError.notReady
        }

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

    /// Job-isolated session memory (never the live chat session).
    private func ensureJobConversation(jobSessionID: String) async throws -> ConversationModel {
        if let existing = jobConversations[jobSessionID] {
            return existing
        }
        try await ensureRuntimeReady()
        guard let repo = repository, let settings = helperModelSettings else {
            throw AgentServiceError.notReady
        }
        let model = try await ConversationModel.makeDefault(
            repository: repo,
            helperModelSettings: settings,
            sessionID: jobSessionID,
            agentIDOverride: JobSessionID.agentID
        )
        jobConversations[jobSessionID] = model
        await AgentServiceStore.shared.log(
            level: .info,
            message: "Job conversation ready session=\(jobSessionID)",
            code: "job_session_ready"
        )
        return model
    }

    private func ensureRuntimeReady() async throws {
        if repository == nil {
            let repo = try await AgentServiceStore.shared.sharedRepository()
            repository = repo
            let settings = await MainActor.run {
                LLMModelSettings(repository: repo)
            }
            helperModelSettings = settings
            await EgressAllowlistService.shared.configure(repository: repo)
            await ContentSensitivityGrantService.shared.configure(repository: repo)
            await UsageLimitsService.shared.configure(repository: repo)
            await EgressAllowlistService.shared.pushToHelper()
        }
        if let settings = helperModelSettings {
            await settings.loadSettings()
        }
    }

    func startTurn(
        request: AgentTurnRequest,
        connectionContext: AgentServiceConnectionContext
    ) async -> AgentTurnAccepted {
        do {
            let isJobWake = request.delivery == .jobResultModal
                || JobSessionID.isJobSession(request.sessionID)
            let model: ConversationModel
            let sid: String
            if isJobWake {
                let jobSession = request.sessionID ?? JobSessionID.make()
                model = try await ensureJobConversation(jobSessionID: jobSession)
                sid = jobSession
            } else {
                model = try await ensureConversation(applicationName: request.applicationName)
                sid = sessionID ?? model.sessionKey.sessionID
            }
            let llmModel = try JSONDecoder().decode(LLMModelChoice.self, from: request.modelJSON)
            let turnID = request.turnID
            let prompt = request.prompt
            let apiKey = request.apiKey
            let apiKeyEmpty = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let delivery = isJobWake ? AgentTurnDelivery.jobResultModal : request.delivery
            let jobID = request.jobID
            let parentSessionID = request.parentSessionID

            tasks[turnID]?.cancel()
            tasks[turnID] = Task {
                await self.executeTurn(
                    turnID: turnID,
                    conversation: model,
                    prompt: prompt,
                    apiKey: apiKey,
                    model: llmModel,
                    connectionContext: connectionContext,
                    delivery: delivery,
                    jobID: jobID,
                    jobSessionID: sid,
                    parentSessionID: parentSessionID
                )
            }

            await AgentServiceStore.shared.log(
                level: .info,
                message: "startTurn accepted id=\(turnID) model=\(llmModel.id) apiKeyEmpty=\(apiKeyEmpty) delivery=\(delivery.rawValue) session=\(sid)",
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
        connectionContext: AgentServiceConnectionContext,
        delivery: AgentTurnDelivery,
        jobID: String?,
        jobSessionID: String,
        parentSessionID: String?
    ) async {
        await AgentServiceStore.shared.log(
            level: .info,
            message: "turn started id=\(turnID) chars=\(prompt.count) delivery=\(delivery.rawValue)",
            code: "turn_start"
        )
        let counter = ChunkCounter()
        let responseBox = ResponseAccumulator()
        let suppressChatStream = delivery == .jobResultModal
        let isJobWake = delivery == .jobResultModal
        let approvalPresenter = AgentServiceApprovalPresenter(
            turnID: turnID,
            sessionID: jobSessionID,
            isJobWake: isJobWake,
            resolveRepository: {
                try await AgentServiceStore.shared.sharedRepository()
            }
        )
        let networkPrompt: @Sendable (String, String) async -> PolicyUserInteraction.PolicyUserDecision = { host, toolName in
            await AgentServiceHITLRouter.requestNetworkAccess(
                host: host,
                toolName: toolName,
                turnID: turnID,
                sessionID: jobSessionID,
                isJobWake: isJobWake,
                resolveRepository: {
                    try await AgentServiceStore.shared.sharedRepository()
                }
            )
        }
        // Process-wide slots: MCP tool tasks do not inherit TaskLocal from the turn task.
        // Job wakes still install here; concurrent user turns remain a known gap (queued later).
        let jobPreflight: TurnProcessContext.JobSchedulingPreflight = { toolName, toolArgumentsJSON in
            try await AgentServiceJobPreflight.approveBeforeSchedulingIfNeeded(
                toolName: toolName,
                toolArgumentsJSON: toolArgumentsJSON
            )
        }
        let policyDecision: TurnProcessContext.PolicyDecisionPrompt = { event in
            await AgentServiceHITLRouter.requestPolicyDecisionViaUISink(event)
        }
        TurnProcessContext.installProcessTurnContext(
            apiKey: apiKey,
            networkAccessPrompt: networkPrompt,
            jobSchedulingPreflight: isJobWake ? nil : jobPreflight,
            policyDecisionPrompt: policyDecision
        )
        defer { TurnProcessContext.clearProcessTurnContext() }
        do {
            try await TurnProcessContext.$conversationAPIKey.withValue(apiKey) {
                try await TurnProcessContext.$networkAccessPrompt.withValue(networkPrompt) {
                    try await TurnProcessContext.$policyDecisionPrompt.withValue(policyDecision) {
                        try await conversation.runTurn(
                            prompt: prompt,
                            apiKey: apiKey,
                            model: model,
                            approvalPresenter: approvalPresenter
                        ) { chunk in
                            let n = counter.increment()
                            if chunk.status == .complete, let text = chunk.chunk, !text.isEmpty {
                                responseBox.append(text)
                            }
                            guard !suppressChatStream else { return }
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
            }

            let chunkCount = counter.value
            if delivery == .jobResultModal {
                let text = responseBox.joined.trimmingCharacters(in: .whitespacesAndNewlines)
                if Task.isCancelled {
                    await AgentServiceStore.shared.log(
                        level: .warning,
                        message: "job wake cancelled turn=\(turnID)",
                        code: "job_wake_cancelled"
                    )
                } else if text.isEmpty {
                    await AgentServiceStore.shared.log(
                        level: .error,
                        message: "job wake empty response turn=\(turnID)",
                        code: "job_wake_empty"
                    )
                } else {
                    await self.finishJobResult(
                        responseText: text,
                        jobID: jobID,
                        jobSessionID: jobSessionID,
                        parentSessionID: parentSessionID
                    )
                }
            } else if Task.isCancelled {
                let err = AgentTurnErrorDTO(turnID: turnID, message: "cancelled", code: "cancelled")
                let data = (try? AgentServiceXPCCodec.encodeTurnError(err)) ?? Data()
                Self.deliverFinish(turnID: turnID, errorJSON: data as NSData, connectionContext: connectionContext)
            } else if chunkCount == 0 {
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
                message: "turn finished id=\(turnID) cancelled=\(Task.isCancelled) chunks=\(chunkCount) delivery=\(delivery.rawValue)",
                code: "turn_finish"
            )
        } catch {
            let message = error.localizedDescription
            await AgentServiceStore.shared.log(
                level: .error,
                message: "turn failed id=\(turnID): \(message)",
                code: "turn_failed"
            )
            if delivery != .jobResultModal {
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
        }
        tasks[turnID] = nil
    }

    private func finishJobResult(
        responseText: String,
        jobID: String?,
        jobSessionID: String,
        parentSessionID: String?
    ) async {
        let result = JobResultDTO(
            jobID: jobID ?? "unknown",
            jobSessionID: jobSessionID,
            parentSessionID: parentSessionID,
            responseText: responseText
        )
        if let repo = repository {
            do {
                try await repo.insertJobResult(
                    DBRepository.JobResultRow(
                        id: result.id,
                        jobID: result.jobID,
                        jobSessionID: result.jobSessionID,
                        parentSessionID: result.parentSessionID,
                        responseText: result.responseText,
                        createdAt: result.createdAt
                    )
                )
            } catch {
                fputs("[AgentService] persist job result failed: \(error.localizedDescription)\n", stderr)
            }
        }
        guard let data = try? JSONEncoder.service.encode(result) else { return }
        _ = data
        DerrickNotificationWake.wakeUIIfNeeded()
        DerrickNotificationSignal.postPoll()
        fputs("[AgentService] job result persisted id=\(result.id) — notification wake requested\n", stderr)
        await AgentServiceStore.shared.log(
            level: .info,
            message: "job result ready job=\(result.jobID) chars=\(responseText.count) uiSink=\(AgentServicePrimaryUISink.shared.clientSink(logLabel: "probe") != nil)",
            code: "job_result_ready"
        )
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
