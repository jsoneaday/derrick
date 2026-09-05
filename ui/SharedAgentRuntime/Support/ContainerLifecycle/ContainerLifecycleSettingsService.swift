import Foundation
import Combine
import DBRepository
import Structure

/// Permanent container lifecycle settings (Settings modal) applied to Docker runners.
@MainActor
final class ContainerLifecycleSettingsService: ObservableObject {
    static let shared = ContainerLifecycleSettingsService()

    static let configKey = "containerLifecycle.v1"

    @Published private(set) var settings: ContainerLifecycleSettings = .default

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
           let decoded = try? JSONDecoder().decode(ContainerLifecycleSettings.self, from: data) {
            settings = decoded.clamped()
        } else {
            settings = .default
        }
        ContainerLifecycleRuntime.apply(settings)
    }

    func savePermanentSettings(_ newSettings: ContainerLifecycleSettings) async {
        let clamped = newSettings.clamped()
        settings = clamped
        ContainerLifecycleRuntime.apply(clamped)
        guard let repository else { return }
        do {
            let data = try JSONEncoder().encode(clamped)
            if let json = String(data: data, encoding: .utf8) {
                try await repository.saveConfig(key: Self.configKey, value: json, username: username, password: password)
            }
        } catch {
            debugLog("Failed to save container lifecycle settings: \(error.localizedDescription)")
        }
    }
}
