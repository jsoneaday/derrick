import Combine
import Foundation
import LLMAgentClient
import DBRepository
import Structure

@MainActor
final class LLMModelThinkingSettings: ObservableObject {
    @Published private var selections: [String: String] = [:]

    private let repository: DBRepository
    private let username: String
    private let password: String
    private static let configKey = "modelThinkingSelections"

    init(repository: DBRepository, username: String = "ui", password: String = "ui") {
        self.repository = repository
        self.username = username
        self.password = password
    }

    func loadSettings() async {
        guard let value = try? await repository.loadConfig(
            key: Self.configKey,
            username: username,
            password: password
        ),
        let data = value.data(using: .utf8),
        let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }
        selections = decoded
    }

    func thinking(for model: LLMModelChoice) -> ModelThinkingOption {
        model.resolvedThinkingOption(id: selections[model.id])
    }

    func setThinking(_ option: ModelThinkingOption, for model: LLMModelChoice) {
        guard model.thinkingOptions.contains(where: { $0.id == option.id }) else { return }
        selections[model.id] = option.id
        Task { await save() }
    }

    private func save() async {
        do {
            let data = try JSONEncoder().encode(selections)
            guard let jsonString = String(data: data, encoding: .utf8) else { return }
            try await repository.saveConfig(
                key: Self.configKey,
                value: jsonString,
                username: username,
                password: password
            )
        } catch {
            debugLog("Failed to persist model thinking selections: \(error.localizedDescription)")
        }
    }
}
