import DBRepository
import Foundation
import Plugin
import Structure
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

    @Test func syncThreadsDropsConversationsThePluginNoLongerReturns() async throws {
        let repository = try makeRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")
        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "slack-connection", displayName: "Slack Connection")
        )
        try await repository.upsertMessagingThread(
            MessagingThreadDTO(
                pluginID: "slack-connection",
                vendorThreadID: "CSECRET",
                title: "#secret"
            )
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
        #expect(Set(threads.map(\.vendorThreadID)) == ["C123"])
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

    @Test func sendOnlyBootstrapSkipsUnsupportedOps() async throws {
        let repository = try makeRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")
        let manifestJSON = """
        {"$schema":"\(PluginContract.agentPluginSchema)","name":"slack-connection","version":"1.0.0",\
        "extensions":{"app.derrick":{"entrypoint":"./app.derrick/plugin.py","role":"connector","messaging_ops":["send_message"]}}}
        """
        let guestSource = "import json, sys\njson.dump([], sys.stdout)"
        let runtimeJSON = #"{"language":"python","entrypoint":"./app.derrick/plugin.py"}"#
        let draft = PluginFactoryRelease(
            pluginID: "slack-connection",
            version: "1.0.0",
            manifestJSON: manifestJSON,
            runtimeJSON: runtimeJSON,
            guestSource: guestSource,
            compiledArtifact: Data(),
            skillFiles: [:],
            contentHash: try PluginContentHash(hex: String(repeating: "0", count: 64)),
            reviewSummary: "ok"
        )
        let release = PluginFactoryRelease(
            pluginID: draft.pluginID,
            version: draft.version,
            manifestJSON: draft.manifestJSON,
            runtimeJSON: draft.runtimeJSON,
            guestSource: draft.guestSource,
            compiledArtifact: draft.compiledArtifact,
            skillFiles: draft.skillFiles,
            contentHash: PluginContentHash.hash(files: draft.packageFiles()),
            reviewSummary: draft.reviewSummary
        )
        try await repository.savePluginFactoryRelease(release)
        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "slack-connection", displayName: "Slack Connection")
        )

        let invoker = ConnectorPluginInvoker { _, _ in
            struct Unexpected: Error {}
            throw Unexpected()
        }
        let adapter = PluginMessagingIngressAdapter(pluginID: "slack-connection", invoker: invoker)
        try await adapter.bootstrap(repository: repository)
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

        final class PollCapture: @unchecked Sendable {
            var vendorThreadIDs: [String] = []
        }
        let capture = PollCapture()
        let invoker = ConnectorPluginInvoker { _, input in
            let event = try JSONDecoder().decode(PluginHopEvent.self, from: input)
            capture.vendorThreadIDs.append(event.params?["vendor_thread_id"]?.stringValue ?? "")
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
        #expect(capture.vendorThreadIDs == ["C123"])
        #expect(inserted.count == 1)
        #expect(inserted.first?.message.body == "hello")
    }

    @Test func pollInboxPollsEachKnownThread() async throws {
        let repository = try makeRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")
        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "slack-connection", displayName: "Slack Connection")
        )
        try await repository.upsertMessagingThread(
            MessagingThreadDTO(
                pluginID: "slack-connection",
                vendorThreadID: "C111",
                title: "#one"
            )
        )
        try await repository.upsertMessagingThread(
            MessagingThreadDTO(
                pluginID: "slack-connection",
                vendorThreadID: "C222",
                title: "#two"
            )
        )

        final class PollCapture: @unchecked Sendable {
            var vendorThreadIDs: [String] = []
        }
        let capture = PollCapture()
        let invoker = ConnectorPluginInvoker { _, input in
            let event = try JSONDecoder().decode(PluginHopEvent.self, from: input)
            let channel = event.params?["vendor_thread_id"]?.stringValue ?? ""
            capture.vendorThreadIDs.append(channel)
            let envelopes = """
            [{"verb":"result.emit","messages":[{"vendor_thread_id":"\(channel)","vendor_message_id":"1.0","direction":"inbound","sender":"alice","body":"hi","created_at":"1710000000.000100"}]}]
            """
            let outcome = ToolExecutionOutcome.completed(
                output: ToolExecutionOutcome.Output(format: .json, value: envelopes)
            )
            return try outcome.encodedJSON()
        }
        let adapter = PluginMessagingIngressAdapter(pluginID: "slack-connection", invoker: invoker)
        let inserted = try await adapter.pollInbox(repository: repository)
        #expect(Set(capture.vendorThreadIDs) == ["C111", "C222"])
        #expect(inserted.count == 2)
    }

    @Test func pollInboxMapsMisassignedVendorThreadIDToPolledThread() async throws {
        let repository = try makeRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")
        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "slack-connection", displayName: "Slack Connection")
        )
        try await repository.upsertMessagingThread(
            MessagingThreadDTO(
                pluginID: "slack-connection",
                vendorThreadID: "CREAL",
                title: "#general"
            )
        )

        let invoker = ConnectorPluginInvoker { _, _ in
            let envelopes = """
            [{"verb":"result.emit","messages":[{"vendor_thread_id":"CWRONG","vendor_message_id":"9.9","direction":"inbound","sender":"alice","body":"hello","created_at":"1710000000.000100"}]}]
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

    @Test func pollInboxUsesListeningSinceWhenNoInboundCursor() async throws {
        let repository = try makeRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")
        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "slack-connection", displayName: "Slack Connection")
        )
        try await repository.setMessagingConnectorListening(pluginID: "slack-connection", listening: true)
        try await repository.upsertMessagingThread(
            MessagingThreadDTO(
                pluginID: "slack-connection",
                vendorThreadID: "C123",
                title: "#general"
            )
        )

        final class Capture: @unchecked Sendable {
            var oldest: String?
        }
        let capture = Capture()
        let invoker = ConnectorPluginInvoker { _, input in
            let event = try JSONDecoder().decode(PluginHopEvent.self, from: input)
            capture.oldest = event.params?["oldest"]?.stringValue
            let envelopes = """
            [{"verb":"result.emit","messages":[]}]
            """
            let outcome = ToolExecutionOutcome.completed(
                output: ToolExecutionOutcome.Output(format: .json, value: envelopes)
            )
            return try outcome.encodedJSON()
        }
        let adapter = PluginMessagingIngressAdapter(pluginID: "slack-connection", invoker: invoker)
        _ = try await adapter.pollInbox(repository: repository)
        #expect(capture.oldest != nil)
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
