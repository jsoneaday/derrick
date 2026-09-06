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

        switch scope {
        case .sendOnly:
            try await testSendOnly(adapter: adapter, repository: repository, channelID: channelID)
        case .sendAndReceive:
            try await testSendAndReceive(
                adapter: adapter,
                repository: repository,
                channelID: channelID,
                environment: environment
            )
        case .fullSync:
            try await testFullSync(
                adapter: adapter,
                repository: repository,
                channelID: channelID,
                environment: environment
            )
        }
    }

    private static func testSendOnly(
        adapter: PluginMessagingIngressAdapter,
        repository: DBRepository,
        channelID: String
    ) async throws {
        let marker = "derrick-e2e-send-only-\(UUID().uuidString.prefix(8))"
        let thread = MessagingThreadDTO(
            pluginID: E2EEnvironment.pluginID,
            vendorThreadID: channelID,
            title: "E2E Send Only"
        )
        try await repository.upsertMessagingThread(thread)
        try await adapter.sendMessage(
            vendorThreadID: channelID,
            text: marker,
            threadID: thread.id,
            repository: repository
        )
        let messages = try await repository.listMessagingMessages(threadID: thread.id, limit: 20)
        guard messages.contains(where: { $0.body == marker && $0.direction == .outbound }) else {
            throw E2EError.messagingTestFailed("Send-only outbound message was not persisted.")
        }
        fputs("[E2E] send-only messaging OK\n", stderr)
    }

    private static func testSendAndReceive(
        adapter: PluginMessagingIngressAdapter,
        repository: DBRepository,
        channelID: String,
        environment: E2EEnvironment
    ) async throws {
        let threads = try await repository.listMessagingThreads(pluginID: E2EEnvironment.pluginID)
        guard !threads.isEmpty else {
            throw E2EError.messagingTestFailed("send+receive sync_threads did not create any threads.")
        }
        guard let thread = threads.first(where: { $0.vendorThreadID == channelID }) else {
            throw E2EError.messagingTestFailed(
                "sync_threads did not include test channel \(channelID). Found: \(threads.map(\.vendorThreadID).joined(separator: ", "))"
            )
        }

        // Receive path: post to Slack outside the adapter, then poll must persist inbound rows.
        let inboundMarker = "derrick-e2e-inbound-\(UUID().uuidString.prefix(8))"
        try await environment.postSlackMessage(channelID: channelID, text: inboundMarker)
        try await Task.sleep(nanoseconds: 750_000_000)
        let inserted = try await adapter.pollInbox(repository: repository)
        let inbound = try await repository.listMessagingMessages(threadID: thread.id, limit: 50)
            .filter { $0.direction == .inbound && $0.body.contains(inboundMarker) }
        guard !inbound.isEmpty else {
            throw E2EError.messagingTestFailed(
                "poll_inbox did not persist an inbound message from Slack (inserted=\(inserted.count))."
            )
        }

        // Send path: adapter must persist outbound rows.
        let outboundMarker = "derrick-e2e-outbound-\(UUID().uuidString.prefix(8))"
        try await adapter.sendMessage(
            vendorThreadID: channelID,
            text: outboundMarker,
            threadID: thread.id,
            repository: repository
        )
        let outbound = try await repository.listMessagingMessages(threadID: thread.id, limit: 50)
        guard outbound.contains(where: { $0.direction == .outbound && $0.body == outboundMarker }) else {
            throw E2EError.messagingTestFailed("send_message did not persist an outbound row.")
        }
        fputs("[E2E] send+receive messaging OK\n", stderr)
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

    private static func ensureThread(
        repository: DBRepository,
        channelID: String,
        title: String
    ) async throws -> MessagingThreadDTO {
        if let existing = try await repository.listMessagingThreads(pluginID: E2EEnvironment.pluginID)
            .first(where: { $0.vendorThreadID == channelID }) {
            return existing
        }
        let thread = MessagingThreadDTO(
            pluginID: E2EEnvironment.pluginID,
            vendorThreadID: channelID,
            title: title
        )
        try await repository.upsertMessagingThread(thread)
        if let persisted = try await repository.listMessagingThreads(pluginID: E2EEnvironment.pluginID)
            .first(where: { $0.vendorThreadID == channelID }) {
            return persisted
        }
        return thread
    }
}
