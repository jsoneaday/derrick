import Foundation
import Combine
import DBRepository
import ServiceContracts

/// Permanent Software Factory Settings flag. Off until the user enables it.
@MainActor
final class SoftwareFactorySettingsService: ObservableObject {
    static let shared = SoftwareFactorySettingsService()

    @Published private(set) var settings: SoftwareFactorySettings = .default

    var isEnabled: Bool { settings.enabled }

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
        if let raw = try? await repository.loadConfig(
            key: SoftwareFactorySettings.configKey,
            username: username,
            password: password
        ),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(SoftwareFactorySettings.self, from: data) {
            settings = decoded
        } else {
            settings = .default
        }
    }

    func setEnabled(_ enabled: Bool) async {
        settings = SoftwareFactorySettings(enabled: enabled)
        guard let repository else { return }
        do {
            let data = try JSONEncoder().encode(settings)
            if let json = String(data: data, encoding: .utf8) {
                try await repository.saveConfig(
                    key: SoftwareFactorySettings.configKey,
                    value: json,
                    username: username,
                    password: password
                )
            }
        } catch {
            debugLog("Failed to save software factory flag: \(error.localizedDescription)")
        }
    }
}
