import Combine
import Foundation
import LLMAgentClient
import MCPServer
import DBRepository

@MainActor
final class LLMModelSettings: ObservableObject {
    @Published var summarizerModel: LLMModelChoice = .defaultHelperModel {
        didSet {
            Task { await save(summarizerModel, forKey: "summarizerModel") }
        }
    }

    @Published var scriptReviewerModel: LLMModelChoice = .defaultHelperModel {
        didSet {
            Task { await save(scriptReviewerModel, forKey: "scriptReviewerModel") }
        }
    }

    @Published var pluginBuilderModel: LLMModelChoice = .defaultHelperModel {
        didSet {
            Task { await save(pluginBuilderModel, forKey: "pluginBuilderModel") }
        }
    }

    @Published var pluginSafetyReviewerModel: LLMModelChoice = .defaultHelperModel {
        didSet {
            Task { await save(pluginSafetyReviewerModel, forKey: "pluginSafetyReviewerModel") }
        }
    }

    @Published var workerAgentModel: LLMModelChoice = .defaultHelperModel {
        didSet {
            Task { await save(workerAgentModel, forKey: "workerAgentModel") }
        }
    }

    private let repository: DBRepository
    private let username: String
    private let password: String

    var settingsRepository: DBRepository { repository }

    init(repository: DBRepository, username: String = "ui", password: String = "ui") {
        self.repository = repository
        self.username = username
        self.password = password
    }

    func loadSettings() async {
        if let model = await Self.load(repository: repository, key: "summarizerModel", username: username, password: password) {
            summarizerModel = model
        }
        if let model = await Self.load(repository: repository, key: "scriptReviewerModel", username: username, password: password) {
            scriptReviewerModel = model
        }
        if let model = await Self.load(repository: repository, key: "pluginBuilderModel", username: username, password: password) {
            pluginBuilderModel = model
        }
        if let model = await Self.load(repository: repository, key: "pluginSafetyReviewerModel", username: username, password: password) {
            pluginSafetyReviewerModel = model
        }
        if let model = await Self.load(repository: repository, key: "workerAgentModel", username: username, password: password) {
            workerAgentModel = model
        }
    }

    private static func load(repository: DBRepository, key: String, username: String, password: String) async -> LLMModelChoice? {
        guard let value = try? await repository.loadConfig(key: key, username: username, password: password),
              let data = value.data(using: .utf8),
              let model = try? JSONDecoder().decode(LLMModelChoice.self, from: data) else {
            return nil
        }
        return model
    }

    private func save(_ model: LLMModelChoice, forKey key: String) async {
        do {
            let data = try JSONEncoder().encode(model)
            if let jsonString = String(data: data, encoding: .utf8) {
                try await repository.saveConfig(key: key, value: jsonString, username: username, password: password)
            }
        } catch {
            debugLog("Failed to persist helper model selection for \(key): \(error.localizedDescription)")
        }
    }
}
