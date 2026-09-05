import Foundation
import AgentRuntime
import Structure

/// DB-backed agent directory: persists registry rows via `DBRepository` and delegates
/// runtime mailbox / turn concurrency to an in-memory `AgentDirectorying` implementation.
public actor DBAgentDirectory: AgentDirectorying {
    public let limits: OrchestrationLimits

    private let repository: DBRepository
    private let applicationName: String
    private let sessionID: String
    private let runtime: InMemoryAgentDirectory

    public init(
        repository: DBRepository,
        applicationName: String,
        sessionID: String,
        limits: OrchestrationLimits = .recommended
    ) async throws {
        self.repository = repository
        self.applicationName = applicationName
        self.sessionID = sessionID
        self.limits = limits
        self.runtime = InMemoryAgentDirectory(limits: limits)
        try await hydrateFromDatabase()
    }

    public func record(for ref: AgentRef) async -> AgentRecord? {
        await runtime.record(for: ref)
    }

    public func allRecords(sessionID: String) async -> [AgentRecord] {
        await runtime.allRecords(sessionID: sessionID)
    }

    @discardableResult
    public func register(_ record: AgentRecord) async throws -> AgentRecord {
        try await ensureChatSessionExists(sessionID: record.ref.sessionID)
        let stored = try await runtime.register(record)
        try await repository.upsertAgentRecord(stored, applicationName: applicationName)
        try await repository.touchChatSessionUpdated(
            applicationName: applicationName,
            sessionID: record.ref.sessionID
        )
        return stored
    }

    public func updateStatus(_ ref: AgentRef, status: AgentStatus) async throws {
        try await runtime.updateStatus(ref, status: status)
        try await repository.updateAgentStatus(
            ref: ref,
            applicationName: applicationName,
            status: status
        )
        try await repository.touchChatSessionUpdated(
            applicationName: applicationName,
            sessionID: ref.sessionID
        )
    }

    public func ensureUserFacingAgent(sessionID: String) async throws -> AgentRecord {
        try await ensureChatSessionExists(sessionID: sessionID)
        let record = try await runtime.ensureUserFacingAgent(sessionID: sessionID)
        try await repository.upsertAgentRecord(record, applicationName: applicationName)
        try await repository.touchChatSessionUpdated(applicationName: applicationName, sessionID: sessionID)
        return record
    }

    public func enqueueOnly(_ envelope: AgentEnvelope) async throws {
        try await runtime.enqueueOnly(envelope)
    }

    public func deliver(
        _ envelope: AgentEnvelope,
        execute: nonisolated(nonsending) @escaping @Sendable (AgentEnvelope) async throws -> Void
    ) async throws {
        let turnID = envelope.id.uuidString
        let preview = String(envelope.body.prefix(240))
        let turnRow = AgentTurnRowDTO(
            id: turnID,
            applicationName: applicationName,
            sessionID: envelope.to.sessionID,
            agentID: envelope.to.agentID,
            correlationID: envelope.correlationId,
            envelopeKind: envelope.kind.rawValue,
            status: .running,
            promptPreview: preview.isEmpty ? nil : preview
        )
        try? await repository.insertAgentTurn(turnRow)

        do {
            try await runtime.deliver(envelope, execute: execute)
            try? await repository.updateAgentTurnStatus(id: turnID, status: .completed)
            try? await repository.touchChatSessionUpdated(
                applicationName: applicationName,
                sessionID: envelope.to.sessionID
            )
        } catch {
            try? await repository.updateAgentTurnStatus(id: turnID, status: .failed)
            throw error
        }
    }

    // MARK: - Hydration

    private func hydrateFromDatabase() async throws {
        let records = try await repository.loadAgentRecords(
            applicationName: applicationName,
            sessionID: sessionID
        )
        for record in records {
            try await runtime.restore(record)
        }
    }

    private func ensureChatSessionExists(sessionID: String) async throws {
        // Job-isolated sessions still need a chat_sessions row — `agents` FKs to it.
        let now = Date.now
        try await repository.upsertChatSession(
            ChatSessionDTO(
                applicationName: applicationName,
                sessionID: sessionID,
                createdAt: now,
                updatedAt: now
            )
        )
    }
}
