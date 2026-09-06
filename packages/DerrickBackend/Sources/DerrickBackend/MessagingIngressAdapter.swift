import DBRepository
import Foundation
import Structure

/// Vendor-specific messaging ingress. Host listens; adapters translate vendor APIs into DB rows.
protocol MessagingIngressAdapter: Sendable {
    var pluginID: String { get }

    func hasCredentials() -> Bool

    /// Ensures thread rows exist (e.g. channel list). Called periodically while listening.
    func syncThreads(repository: DBRepository) async throws

    /// Fetches new vendor messages and persists them. Returns rows inserted this poll.
    func pollInbox(repository: DBRepository) async throws -> [MessagingPersistResult]

    /// Sends an outbound message through the connector plugin.
    func sendMessage(
        vendorThreadID: String,
        text: String,
        threadID: String,
        repository: DBRepository
    ) async throws
}

extension MessagingIngressAdapter {
    public func bootstrap(repository: DBRepository) async throws {
        let manifestJSON = try await repository.listLatestPluginFactoryManifests()
            .first(where: { $0.pluginID == pluginID })?
            .manifestJSON ?? ""
        if PluginFactoryValidationExpectations.supportsSyncThreads(manifestJSON: manifestJSON) {
            try await syncThreads(repository: repository)
        }
    }
}

enum MessagingIngressRegistry {
    static func adapter(for pluginID: String) -> (any MessagingIngressAdapter)? {
        PluginMessagingIngressAdapter(pluginID: pluginID)
    }
}
