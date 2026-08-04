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

    @Published var pythonScriptReviewerModel: LLMModelChoice = .defaultHelperModel {
        didSet {
            Task { await save(pythonScriptReviewerModel, forKey: "pythonScriptReviewerModel") }
        }
    }

    private let repository: DBRepository
    private let username: String
    private let password: String

    init(repository: DBRepository, username: String = "ui", password: String = "ui") {
        self.repository = repository
        self.username = username
        self.password = password
    }

    func loadSettings() async {
        if let model = await Self.load(repository: repository, key: "summarizerModel", username: username, password: password) {
            summarizerModel = model
        }
        if let model = await Self.load(repository: repository, key: "pythonScriptReviewerModel", username: username, password: password) {
            pythonScriptReviewerModel = model
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
