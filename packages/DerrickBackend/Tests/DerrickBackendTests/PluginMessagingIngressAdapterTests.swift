import DBRepository
import Foundation
import Plugin
import ServiceContracts
import Testing
@testable import DerrickBackend

@Suite struct PluginMessagingIngressAdapterTests {
    @Test func syncThreadsPersistsReturnedThreads() async throws {
        let repository = try makeRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")
        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "slack-connection", displayName: "Slack Connection")
        )

        let invoker = ConnectorPluginInvoker { _, _ in
            let envelopes = """
            [{"verb":"result.emit","threads":[{"vendor_thread_id":"C123","title":"#general"}]}]
            """
            let outcome = ToolExecutionOutcome.completed(
                output: ToolExecutionOutcome.Output(format: .json, value: envelopes)
            )
            return try outcome.encodedJSON()
        }
        let adapter = PluginMessagingIngressAdapter(pluginID: "slack-connection", invoker: invoker)
        try await adapter.syncThreads(repository: repository)

        let threads = try await repository.listMessagingThreads(pluginID: "slack-connection")
        #expect(threads.count == 1)
        #expect(threads.first?.vendorThreadID == "C123")
    }

    @Test func sendMessagePersistsOutboundRow() async throws {
        let repository = try makeRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")
        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "slack-connection", displayName: "Slack Connection")
        )
        let thread = MessagingThreadDTO(
            pluginID: "slack-connection",
            vendorThreadID: "C123",
            title: "#general"
        )
        try await repository.upsertMessagingThread(thread)

        let invoker = ConnectorPluginInvoker { _, _ in
            let envelopes = """
            [{"verb":"result.emit","sent_message":{"vendor_message_id":"42.0","created_at":"1710000001.000100"}}]
            """
            let outcome = ToolExecutionOutcome.completed(
                output: ToolExecutionOutcome.Output(format: .json, value: envelopes)
            )
            return try outcome.encodedJSON()
        }
        let adapter = PluginMessagingIngressAdapter(pluginID: "slack-connection", invoker: invoker)
        try await adapter.sendMessage(
            vendorThreadID: "C123",
            text: "hello slack",
            threadID: thread.id,
            repository: repository
        )
        let messages = try await repository.listMessagingMessages(threadID: thread.id, limit: 10)
        #expect(messages.map(\.body) == ["hello slack"])
        #expect(messages.first?.direction == .outbound)
    }

    @Test func pollInboxReturnsInsertedInboundRows() async throws {
        let repository = try makeRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")
        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "slack-connection", displayName: "Slack Connection")
        )
        try await repository.upsertMessagingThread(
            MessagingThreadDTO(
                pluginID: "slack-connection",
                vendorThreadID: "C123",
                title: "#general"
            )
        )

        let invoker = ConnectorPluginInvoker { _, _ in
            let envelopes = """
            [{"verb":"result.emit","messages":[{"vendor_thread_id":"C123","vendor_message_id":"9.9","direction":"inbound","sender":"alice","body":"hello","created_at":"1710000000.000100"}]}]
            """
            let outcome = ToolExecutionOutcome.completed(
                output: ToolExecutionOutcome.Output(format: .json, value: envelopes)
            )
            return try outcome.encodedJSON()
        }
        let adapter = PluginMessagingIngressAdapter(pluginID: "slack-connection", invoker: invoker)
        let inserted = try await adapter.pollInbox(repository: repository)
        #expect(inserted.count == 1)
        #expect(inserted.first?.message.body == "hello")
    }

    private func makeRepository() throws -> DBRepository {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return DBRepository(
            configuration: DBRepositoryConfiguration(
                applicationName: "ui",
                databaseName: "derrick",
                databaseDirectoryURL: directory,
                username: "app-user",
                password: "app-secret"
            )
        )
    }
}
