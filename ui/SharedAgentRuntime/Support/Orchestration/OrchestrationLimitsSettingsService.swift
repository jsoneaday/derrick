import Foundation
import Combine
import DBRepository
import ServiceContracts

/// Permanent multi-agent orchestration limits (Settings modal).
@MainActor
final class OrchestrationLimitsSettingsService: ObservableObject {
    static let shared = OrchestrationLimitsSettingsService()

    static let configKey = "orchestrationLimits.v1"

    @Published private(set) var limits: OrchestrationLimits = .default

    private var repository: DBRepository?
    private let username = "ui"
    private let password = "ui"

    private init() {}

    func configure(repository: DBRepository) async {
        self.repository = repository
        await reload()
    }

    func reload() async {
        guard let repository else { return }
        if let raw = try? await repository.loadConfig(key: Self.configKey, username: username, password: password),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(OrchestrationLimits.self, from: data) {
            limits = decoded.clamped()
        } else {
            limits = .default
        }
        OrchestrationLimitsRuntime.apply(limits)
    }

    func savePermanentLimits(_ newLimits: OrchestrationLimits) async {
        let clamped = newLimits.clamped()
        limits = clamped
        OrchestrationLimitsRuntime.apply(clamped)
        guard let repository else { return }
        do {
            let data = try JSONEncoder().encode(clamped)
            if let json = String(data: data, encoding: .utf8) {
                try await repository.saveConfig(key: Self.configKey, value: json, username: username, password: password)
            }
        } catch {
            debugLog("Failed to save orchestration limits: \(error.localizedDescription)")
        }
    }
}
