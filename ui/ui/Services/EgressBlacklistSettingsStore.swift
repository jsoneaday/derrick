import Foundation
import Combine
import ServiceContracts

/// Settings-facing soft blacklist. Persist only through derrickd.
@MainActor
final class EgressBlacklistSettingsStore: ObservableObject {
    static let shared = EgressBlacklistSettingsStore()

    @Published private(set) var entries: [EgressBlacklistEntryDTO] = []

    private init() {}

    func reload() async throws {
        entries = try await AgentServiceClient.shared.listEgressBlacklist()
            .sorted { $0.displayPattern < $1.displayPattern }
    }

    func add(pattern: String) async throws {
        try await AgentServiceClient.shared.addEgressBlacklist(pattern: pattern)
        try await reload()
    }

    func remove(id: String) async throws {
        try await AgentServiceClient.shared.removeEgressBlacklist(id: id)
        try await reload()
    }
}
