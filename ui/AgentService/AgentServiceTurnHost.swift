import Foundation
import DBRepository
import DerrickBackend
import LLMAgentClient
import PolicyUserInteraction
import Structure

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

    private var conversations: [String: ConversationModel] = [:]
    /// Primary interactive UI session (when client omits `sessionID`).
    private var primaryUISessionID: String?
    private var repository: DBRepository?
    private var helperModelSettings: LLMModelSettings?
    /// Per-session serial turn chains (one in-flight turn per session).
    private var sessionTurnTails: [String: Task<Void, Never>] = [:]
    /// Identifies the turn represented by each cached tail so an older turn
    /// cannot clear a newer queued tail during cleanup.
    private var sessionTurnTailIDs: [String: String] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var turnSessionIDs: [String: String] = [:]

    func ensureConversation(
        sessionID: String,
        applicationName: String,
        agentIDOverride: String? = nil
    ) async throws -> ConversationModel {
        if let existing = conversations[sessionID] {
            return existing
        }
        try await ensureRuntimeReady()
        guard let repo = repository, let settings = helperModelSettings else {
            throw AgentServiceError.notReady
        }

        let model = try await ConversationModel.makeDefault(
            repository: repo,
            helperModelSettings: settings,
            sessionID: sessionID,
            agentIDOverride: agentIDOverride
        )
        conversations[sessionID] = model
        if agentIDOverride == nil, JobSessionID.isJobSession(sessionID) == false {
            primaryUISessionID = sessionID
        }
        evictInactiveConversations(except: sessionID)
        await AgentServiceStore.shared.log(
            level: .info,
            message: "Turn host session ready session=\(sessionID)",
            code: "turn_host_ready"
        )
        return model
    }

    private func resolveSessionID(
        request: AgentTurnRequest,
        isJobWake: Bool
    ) -> String {
        if isJobWake {
            if let explicit = request.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !explicit.isEmpty {
                return explicit
            }
            return JobSessionID.make()
        }
        if let explicit = request.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            // Live chat must never reuse a job-isolated session (queues behind hung wakes).
            if JobSessionID.isJobSession(explicit) {
                if let primary = primaryUISessionID, !JobSessionID.isJobSession(primary) {
                    return primary
                }
                let fresh = UUID().uuidString
                primaryUISessionID = fresh
                return fresh
            }
            return explicit
        }
        if let primary = primaryUISessionID, !JobSessionID.isJobSession(primary) {
            return primary
        }
        let fresh = UUID().uuidString
        primaryUISessionID = fresh
        return fresh
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
            await ContainerLifecycleSettingsService.shared.configure(repository: repo)
            await OrchestrationLimitsSettingsService.shared.configure(repository: repo)
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
            let sid = resolveSessionID(request: request, isJobWake: isJobWake)
            let agentOverride = isJobWake ? JobSessionID.agentID : nil
            if !isJobWake {
                // Cancel any stuck background wake on job-* queues so interactive chat is never blocked.
                cancelAllJobSessionTurns()
            }
            let model = try await ensureConversation(
                sessionID: sid,
                applicationName: request.applicationName,
                agentIDOverride: agentOverride
            )
            let llmModel = try JSONDecoder().decode(LLMModelChoice.self, from: request.modelJSON)
            let thinking = try request.thinkingJSON.map {
                try JSONDecoder().decode(ModelThinkingOption.self, from: $0)
            }
            let turnID = request.turnID
            let prompt = request.prompt
            let apiKey = request.apiKey
            let apiKeyEmpty = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let delivery = isJobWake ? AgentTurnDelivery.jobResultModal : request.delivery
            let jobID = request.jobID
            let parentSessionID = request.parentSessionID

            tasks[turnID]?.cancel()
            let turnTask = enqueueSessionTurn(sessionID: sid, turnID: turnID) {
                await self.executeTurn(
                    turnID: turnID,
                    conversation: model,
                    prompt: prompt,
                    apiKey: apiKey,
                    model: llmModel,
                    thinking: thinking,
                    connectionContext: connectionContext,
                    delivery: delivery,
                    jobID: jobID,
                    jobSessionID: sid,
                    parentSessionID: parentSessionID
                )
            }
            tasks[turnID] = turnTask
            turnSessionIDs[turnID] = sid

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
                sessionID: primaryUISessionID ?? "",
                message: message
            )
        }
    }

    func cancelTurn(turnID: String) {
        tasks[turnID]?.cancel()
        tasks[turnID] = nil
        turnSessionIDs[turnID] = nil
    }

    /// Drop hung job-wake turn chains so a live chatStream cannot wait forever behind HITL.
    private func cancelAllJobSessionTurns() {
        let jobTurnIDs = turnSessionIDs.compactMap { turnID, sessionID -> String? in
            JobSessionID.isJobSession(sessionID) ? turnID : nil
        }
        for turnID in jobTurnIDs {
            tasks[turnID]?.cancel()
            tasks[turnID] = nil
            turnSessionIDs[turnID] = nil
            fputs("[AgentService] cancelled job-session turn=\(turnID) to unblock interactive chat\n", stderr)
        }
        let jobSessionIDs = sessionTurnTails.keys.filter { JobSessionID.isJobSession($0) }
        for sessionID in jobSessionIDs {
            sessionTurnTails[sessionID]?.cancel()
            sessionTurnTails[sessionID] = nil
            sessionTurnTailIDs[sessionID] = nil
            conversations[sessionID] = nil
        }
    }

    private func enqueueSessionTurn(
        sessionID: String,
        turnID: String,
        operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let previous = sessionTurnTails[sessionID]
        let task = Task {
            if let previous {
                _ = await previous.result
            }
            guard !Task.isCancelled else { return }
            await operation()
        }
        sessionTurnTails[sessionID] = task
        sessionTurnTailIDs[sessionID] = turnID
        return task
    }

    private func executeTurn(
        turnID: String,
        conversation: ConversationModel,
        prompt: String,
        apiKey: String,
        model: LLMModelChoice,
        thinking: ModelThinkingOption?,
        connectionContext: AgentServiceConnectionContext,
        delivery: AgentTurnDelivery,
        jobID: String?,
        jobSessionID: String,
        parentSessionID: String?
    ) async {
        defer {
            finishTurnState(
                turnID: turnID,
                sessionID: jobSessionID,
                evictJobConversation: delivery == .jobResultModal
            )
        }
        guard !Task.isCancelled else {
            return
        }
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
        let networkPrompt: @Sendable (String, String) async -> PolicyUserDecision = { host, toolName in
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
        let policyDecision: TurnProcessContext.PolicyDecisionPrompt = { event in
            await AgentServiceHITLRouter.requestPolicyDecisionViaUISink(event)
        }
        let policyNotice: TurnProcessContext.PolicyNoticePublisher = { event in
            _ = await AgentServiceHITLRouter.requestPolicyDecisionViaUISink(event)
        }
        let contextID = ExecutionContextID(
            sessionID: jobSessionID,
            agentID: conversation.sessionKey.agentID
        )
        TurnProcessContext.install(
            for: contextID,
            apiKey: apiKey,
            networkAccessPrompt: networkPrompt,
            policyDecisionPrompt: policyDecision,
            policyNoticePublisher: policyNotice
        )
        defer { TurnProcessContext.clear(contextID: contextID) }
        do {
            try await TurnProcessContext.$executionContextID.withValue(contextID) {
                try await TurnProcessContext.$conversationAPIKey.withValue(apiKey) {
                    try await TurnProcessContext.$networkAccessPrompt.withValue(networkPrompt) {
                        try await TurnProcessContext.$policyDecisionPrompt.withValue(policyDecision) {
                            try await TurnProcessContext.$policyNoticePublisher.withValue(policyNotice) {
                                if !isJobWake, let repo = self.repository {
                                    switch await BlacklistPromptPreflight.approveUserPrompt(prompt, repository: repo) {
                                    case .allowed:
                                        break
                                    case .denied(let message):
                                        let dto = AgentTurnChunkDTO(
                                            turnID: turnID,
                                            sessionID: jobSessionID,
                                            status: "complete",
                                            chunk: message,
                                            toolName: nil
                                        )
                                        if let data = try? AgentServiceXPCCodec.encodeTurnChunk(dto) {
                                            _ = Self.deliverChunk(
                                                turnID: turnID,
                                                data: data as NSData,
                                                connectionContext: connectionContext
                                            )
                                        }
                                        Self.deliverFinish(
                                            turnID: turnID,
                                            errorJSON: Data() as NSData,
                                            connectionContext: connectionContext
                                        )
                                        await AgentServiceStore.shared.log(
                                            level: .info,
                                            message: "turn blocked by blacklist preflight id=\(turnID)",
                                            code: "blacklist_preflight_denied"
                                        )
                                        return
                                    }
                                }
                                try await conversation.runTurn(
                                    prompt: prompt,
                                    apiKey: apiKey,
                                    model: model,
                                    thinking: thinking,
                                    approvalPresenter: approvalPresenter
                                ) { chunk in
                                    let n = counter.increment()
                                    if (chunk.status == .complete || chunk.isProgress),
                                       let text = chunk.chunk,
                                       !text.isEmpty {
                                        responseBox.append(text)
                                    }
                                    guard !suppressChatStream else { return }
                                    let dto = AgentTurnChunkDTO(
                                        turnID: turnID,
                                        sessionID: jobSessionID,
                                        status: chunk.status.rawValue,
                                        chunk: chunk.chunk,
                                        toolName: chunk.toolName,
                                        isProgress: chunk.isProgress
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
                    let failureFallback = await Self.jobFailureFallbackText(
                        repository: repository,
                        jobID: jobID
                    )
                    if let failureFallback {
                        await self.finishJobResult(
                            responseText: failureFallback,
                            jobID: jobID,
                            jobSessionID: jobSessionID,
                            parentSessionID: parentSessionID
                        )
                    } else {
                        await AgentServiceStore.shared.log(
                            level: .error,
                            message: "job wake empty response turn=\(turnID)",
                            code: "job_wake_empty"
                        )
                    }
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
    }

    /// Releases per-turn task chains and idle conversation models.
    ///
    /// Job sessions are one-shot and must not remain cached after completion.
    /// Interactive sessions are retained only while they are the primary UI
    /// session or still have another turn queued or running.
    private func finishTurnState(
        turnID: String,
        sessionID: String,
        evictJobConversation: Bool
    ) {
        tasks[turnID] = nil
        turnSessionIDs[turnID] = nil

        if sessionTurnTailIDs[sessionID] == turnID {
            sessionTurnTails[sessionID] = nil
            sessionTurnTailIDs[sessionID] = nil
        }

        let hasAnotherTurn = turnSessionIDs.values.contains(sessionID)
        if evictJobConversation || (sessionID != primaryUISessionID && !hasAnotherTurn) {
            conversations[sessionID] = nil
        }
    }

    /// Prevents abandoned session models from accumulating in the long-lived
    /// AgentService process. Active sessions remain available until their turn
    /// cleanup runs.
    private func evictInactiveConversations(except sessionID: String) {
        let activeSessionIDs = Set(turnSessionIDs.values)
        let inactiveSessionIDs = conversations.keys.filter { cachedSessionID in
            cachedSessionID != sessionID
                && !activeSessionIDs.contains(cachedSessionID)
                && (JobSessionID.isJobSession(cachedSessionID)
                    || cachedSessionID != primaryUISessionID)
        }
        for inactiveSessionID in inactiveSessionIDs {
            conversations[inactiveSessionID] = nil
        }
    }

    private static func jobFailureFallbackText(repository: DBRepository?, jobID: String?) async -> String? {
        guard let repository, let jobID else { return nil }
        guard (try? await repository.fetchJobStatus(id: jobID)) == JobStatus.failed.rawValue else {
            return nil
        }
        guard let message = try? await repository.fetchJobFailureMessage(id: jobID) else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func finishJobResult(
        responseText: String,
        jobID: String?,
        jobSessionID: String,
        parentSessionID: String?
    ) async {
        var text = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let jobID, let repo = repository,
           (try? await repo.fetchJobStatus(id: jobID)) == JobStatus.failed.rawValue,
           let message = try? await repo.fetchJobFailureMessage(id: jobID),
           let detail = JobFailureDisplay.technicalDetail(from: message) {
            let failureCode = try? await repo.fetchJobErrorCode(id: jobID)
            text = JobFailureDisplay.composePresentation(
                responseText: text,
                failureDetail: detail,
                failureCode: failureCode
            )
        }
        let result = JobResultDTO(
            jobID: jobID ?? "unknown",
            jobSessionID: jobSessionID,
            parentSessionID: parentSessionID,
            responseText: text
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
                await JobResultNotifier.notifyCompletion(
                    resultID: result.id,
                    jobID: result.jobID,
                    responseText: result.responseText,
                    repository: repo
                )
            } catch {
                fputs("[AgentService] persist job result failed: \(error.localizedDescription)\n", stderr)
            }
        }
        fputs("[AgentService] job result persisted id=\(result.id) — daemon notify requested\n", stderr)
        await AgentServiceStore.shared.log(
            level: .info,
            message: "job result ready job=\(result.jobID) chars=\(text.count)",
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
        if !delivered, let ui = AgentServicePrimaryUISink.shared.clientSink(logLabel: "chunk-fallback") {
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
        if !delivered, let ui = AgentServicePrimaryUISink.shared.clientSink(logLabel: "finish-fallback") {
            ui.turnDidFinish(turnID, errorJSON: errorJSON)
            delivered = true
        }
        return delivered
    }
}
