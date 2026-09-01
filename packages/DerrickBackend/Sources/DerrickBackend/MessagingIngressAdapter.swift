import DBRepository
import Foundation
import ServiceContracts

/// Vendor-specific messaging ingress. Host listens; adapters translate vendor APIs into DB rows.
protocol MessagingIngressAdapter: Sendable {
    var pluginID: String { get }

    func hasCredentials() -> Bool

    /// Ensures thread rows exist (e.g. channel list). Called periodically while listening.
    func syncThreads(repository: DBRepository) async throws

    /// Fetches new vendor messages and persists them. Returns rows inserted this poll.
    func pollInbox(repository: DBRepository) async throws -> [MessagingPersistResult]
}

enum MessagingIngressRegistry {
    static let adapters: [any MessagingIngressAdapter] = [
        SlackMessagingIngressAdapter(),
    ]

    static func adapter(for pluginID: String) -> (any MessagingIngressAdapter)? {
        adapters.first { $0.pluginID == pluginID }
    }
}
