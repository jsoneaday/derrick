import DBRepository
import DerrickBackend
import Foundation
import Structure

enum E2EMessagingTests {
    static func run(
        scope: PluginFactoryCreateInput.ConnectorScope,
        adapter: PluginMessagingIngressAdapter,
        repository: DBRepository,
        channelID: String,
        environment: E2EEnvironment
    ) async throws {
        guard adapter.hasCredentials() else {
            throw E2EError.messagingTestFailed("Connector credentials are missing.")
        }

        try await E2EEnvironment.ensureConnectorRegistered(
            repository: repository,
            listening: true
        )
        try await adapter.bootstrap(repository: repository)
        _ = scope

        try await testFullSync(
            adapter: adapter,
            repository: repository,
            channelID: channelID,
            environment: environment
        )
    }

    private static func testFullSync(
        adapter: PluginMessagingIngressAdapter,
        repository: DBRepository,
        channelID: String,
        environment: E2EEnvironment
    ) async throws {
        let threads = try await repository.listMessagingThreads(pluginID: E2EEnvironment.pluginID)
        guard !threads.isEmpty else {
            throw E2EError.messagingTestFailed("full sync did not create any threads.")
        }
        let thread = threads.first(where: { $0.vendorThreadID == channelID })
            ?? threads[0]

        let inboundMarker = "derrick-e2e-full-inbound-\(UUID().uuidString.prefix(8))"
        try await environment.postSlackMessage(channelID: thread.vendorThreadID, text: inboundMarker)
        try await Task.sleep(nanoseconds: 750_000_000)
        let inserted = try await adapter.pollInbox(repository: repository)
        let inbound = try await repository.listMessagingMessages(threadID: thread.id, limit: 50)
            .filter { $0.direction == .inbound && $0.body.contains(inboundMarker) }
        guard !inbound.isEmpty else {
            throw E2EError.messagingTestFailed(
                "full sync poll_inbox did not persist an inbound message (inserted=\(inserted.count))."
            )
        }

        let outboundMarker = "derrick-e2e-full-outbound-\(UUID().uuidString.prefix(8))"
        try await adapter.sendMessage(
            vendorThreadID: thread.vendorThreadID,
            text: outboundMarker,
            threadID: thread.id,
            repository: repository
        )
        let outbound = try await repository.listMessagingMessages(threadID: thread.id, limit: 50)
        guard outbound.contains(where: { $0.direction == .outbound && $0.body == outboundMarker }) else {
            throw E2EError.messagingTestFailed("full sync send_message did not persist an outbound row.")
        }
        fputs("[E2E] full sync messaging OK\n", stderr)
    }
}
