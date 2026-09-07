import Combine
import DBRepository
import Foundation
import LLMAgentClient
import Structure

@MainActor
final class AgentProfileStore: ObservableObject {
    static let shared = AgentProfileStore()

    @Published private(set) var profiles: [AgentProfile] = []
    @Published private(set) var lastError: String?

    private var repository: DBRepository?

    var enabledProfiles: [AgentProfile] {
        profiles.filter(\.isEnabled)
    }

    var defaultProfile: AgentProfile? {
        profile(handle: AgentProfileHandle.orchestrator)
            ?? enabledProfiles.first
    }

    func configure(repository: DBRepository) async {
        self.repository = repository
        await reload()
    }

    func reload() async {
        guard let repository else { return }
        do {
            try await ensureBuiltins(repository: repository)
            profiles = try await repository.listAgentProfiles()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func profile(handle: String) -> AgentProfile? {
        let normalized = handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return enabledProfiles.first { $0.handle == normalized }
    }

    func resolveProfile(
        explicitHandle: String?,
        message: String
    ) -> (profile: AgentProfile, prompt: String)? {
        let parsed = AgentProfileTokenParser.parse(message: message)
        let handle = parsed.handle
            ?? explicitHandle
            ?? AgentProfileHandle.orchestrator
        guard let profile = profile(handle: handle) ?? defaultProfile else { return nil }
        let prompt = parsed.handle != nil
            ? parsed.body
            : message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }
        return (profile, prompt)
    }

    @discardableResult
    func upsert(_ profile: AgentProfile) async throws -> AgentProfile {
        guard let repository else {
            throw AgentProfileStoreError.notReady
        }
        var next = profile
        if let normalized = AgentProfileHandle.normalize(next.handle) {
            next.handle = normalized
        } else {
            throw AgentProfileStoreError.invalidHandle
        }
        next.updatedAt = .now
        try await repository.upsertAgentProfile(next)
        await reload()
        return next
    }

    func delete(id: String) async throws {
        guard let repository else {
            throw AgentProfileStoreError.notReady
        }
        try await repository.deleteAgentProfile(id: id)
        await reload()
    }

    private func ensureBuiltins(repository: DBRepository) async throws {
        let existing = try await repository.agentProfile(handle: AgentProfileHandle.orchestrator)
        guard existing == nil else { return }
        let modelJSON = try JSONEncoder().encode(LLMModelChoice.defaultHelperModel)
        try await repository.upsertAgentProfile(AgentProfile.orchestratorDefault(modelJSON: modelJSON))
    }
}

enum AgentProfileStoreError: Error, LocalizedError {
    case notReady
    case invalidHandle

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "Agent profiles are not ready yet."
        case .invalidHandle:
            return "Profile handle must use letters, numbers, and underscores."
        }
    }
}
