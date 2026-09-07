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

    @Test func syncThreadsEmptySuccessfulListDoesNotThrow() async throws {
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
            [{"verb":"result.emit","threads":[]}]
            """
            let outcome = ToolExecutionOutcome.completed(
                output: ToolExecutionOutcome.Output(format: .json, value: envelopes)
            )
            return try outcome.encodedJSON()
        }
        let adapter = PluginMessagingIngressAdapter(pluginID: "slack-connection", invoker: invoker)
        try await adapter.syncThreads(repository: repository)

        let threads = try await repository.listMessagingThreads(pluginID: "slack-connection")
        #expect(threads.isEmpty)
    }

    @Test func syncThreadsEmptyVendorErrorDoesNotWipeCatalog() async throws {
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
            [{"verb":"result.emit","threads":[],"title":"Slack list failed","summary":"invalid_auth"}]
            """
            let outcome = ToolExecutionOutcome.completed(
                output: ToolExecutionOutcome.Output(format: .json, value: envelopes)
            )
            return try outcome.encodedJSON()
        }
        let adapter = PluginMessagingIngressAdapter(pluginID: "slack-connection", invoker: invoker)
        do {
            try await adapter.syncThreads(repository: repository)
            Issue.record("Expected vendor error to fail sync_threads")
        } catch let error as ConnectorMessagingError {
            #expect(error.localizedDescription.contains("invalid_auth"))
        }

        let threads = try await repository.listMessagingThreads(pluginID: "slack-connection")
        #expect(threads.map(\.vendorThreadID) == ["CSECRET"])
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

    @Test func sendMessagePassesParentVendorMessageID() async throws {
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

        let capture = ParentCapture()
        let invoker = ConnectorPluginInvoker { _, input in
            let event = try JSONDecoder().decode(PluginHopEvent.self, from: input)
            capture.parent = event.params?["parent_vendor_message_id"]?.stringValue
            let envelopes = """
            [{"verb":"result.emit","sent_message":{"vendor_message_id":"42.1","created_at":"1710000001.000100"}}]
            """
            let outcome = ToolExecutionOutcome.completed(
                output: ToolExecutionOutcome.Output(format: .json, value: envelopes)
            )
            return try outcome.encodedJSON()
        }
        let adapter = PluginMessagingIngressAdapter(pluginID: "slack-connection", invoker: invoker)
        try await adapter.sendMessage(
            vendorThreadID: "C123",
            text: "in thread",
            threadID: thread.id,
            parentVendorMessageID: "171.1",
            repository: repository
        )
        #expect(capture.parent == "171.1")
        let replies = try await repository.listMessagingMessages(
            threadID: thread.id,
            filter: .replyThread(parentVendorMessageID: "171.1")
        )
        #expect(replies.map(\.body) == ["in thread"])
        #expect(replies.first?.parentVendorMessageID == "171.1")
        let channel = try await repository.listMessagingMessages(
            threadID: thread.id,
            filter: .channelRoots
        )
        #expect(channel.isEmpty)
    }

    @Test func pollConversationPassesParentVendorMessageID() async throws {
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

        let capture = ParentCapture()
        let invoker = ConnectorPluginInvoker { _, input in
            let event = try JSONDecoder().decode(PluginHopEvent.self, from: input)
            capture.parent = event.params?["parent_vendor_message_id"]?.stringValue
            let envelopes = """
            [{"verb":"result.emit","messages":[{"vendor_thread_id":"C123","vendor_message_id":"171.2","direction":"inbound","sender":"U2","body":"hi this is a thread","created_at":"1710000002.000100","parent_vendor_message_id":"171.1"}]}]
            """
            let outcome = ToolExecutionOutcome.completed(
                output: ToolExecutionOutcome.Output(format: .json, value: envelopes)
            )
            return try outcome.encodedJSON()
        }
        let adapter = PluginMessagingIngressAdapter(pluginID: "slack-connection", invoker: invoker)
        let inserted = try await adapter.pollConversation(
            vendorThreadID: "C123",
            parentVendorMessageID: "171.1",
            repository: repository
        )
        #expect(capture.parent == "171.1")
        #expect(inserted.contains(where: { $0.message.body == "hi this is a thread" }))
        let channel = try await repository.listMessagingMessages(
            threadID: inserted[0].thread.id,
            filter: .channelRoots
        )
        #expect(channel.isEmpty)
        let replies = try await repository.listMessagingMessages(
            threadID: inserted[0].thread.id,
            filter: .replyThread(parentVendorMessageID: "171.1")
        )
        #expect(replies.map(\.body) == ["hi this is a thread"])
    }

    @Test func pollConversationDoesNotSendOldestWhenParentAlreadyExists() async throws {
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
        _ = try await repository.persistMessagingInbound(
            MessagingInboundRecord(
                pluginID: "slack-connection",
                vendorThreadID: "C123",
                threadTitle: "#general",
                vendorMessageID: "171.1",
                sender: "alice",
                body: "root",
                createdAt: Date(timeIntervalSince1970: 1_710_000_000),
                replyCount: 1
            )
        )

        final class Capture: @unchecked Sendable {
            var oldest: String?
            var parent: String?
        }
        let capture = Capture()
        let invoker = ConnectorPluginInvoker { _, input in
            let event = try JSONDecoder().decode(PluginHopEvent.self, from: input)
            capture.oldest = event.params?["oldest"]?.stringValue
            capture.parent = event.params?["parent_vendor_message_id"]?.stringValue
            let envelopes = """
            [{"verb":"result.emit","messages":[{"vendor_thread_id":"C123","vendor_message_id":"171.2","direction":"inbound","sender":"U2","body":"hi this is a thread","created_at":"1710000002.000100","parent_vendor_message_id":"171.1"}]}]
            """
            let outcome = ToolExecutionOutcome.completed(
                output: ToolExecutionOutcome.Output(format: .json, value: envelopes)
            )
            return try outcome.encodedJSON()
        }
        let adapter = PluginMessagingIngressAdapter(pluginID: "slack-connection", invoker: invoker)
        _ = try await adapter.pollConversation(
            vendorThreadID: "C123",
            parentVendorMessageID: "171.1",
            repository: repository
        )
        #expect(capture.parent == "171.1")
        #expect(capture.oldest == nil)
    }

    @Test func pollInboxFetchesReplyThreadWhenParentReplyCountIsAhead() async throws {
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
        _ = try await repository.persistMessagingInbound(
            MessagingInboundRecord(
                pluginID: "slack-connection",
                vendorThreadID: "C123",
                threadTitle: "#general",
                vendorMessageID: "171.1",
                sender: "alice",
                body: "root",
                createdAt: Date(timeIntervalSince1970: 1_710_000_000),
                replyCount: 1
            )
        )

        final class Capture: @unchecked Sendable {
            var parents: [String] = []
            var oldests: [String?] = []
        }
        let capture = Capture()
        let invoker = ConnectorPluginInvoker { _, input in
            let event = try JSONDecoder().decode(PluginHopEvent.self, from: input)
            capture.parents.append(event.params?["parent_vendor_message_id"]?.stringValue ?? "")
            capture.oldests.append(event.params?["oldest"]?.stringValue)
            let parent = event.params?["parent_vendor_message_id"]?.stringValue ?? ""
            let envelopes: String
            if parent.isEmpty {
                envelopes = #"[{"verb":"result.emit","messages":[]}]"#
            } else {
                envelopes = """
                [{"verb":"result.emit","messages":[{"vendor_thread_id":"C123","vendor_message_id":"171.2","direction":"inbound","sender":"U2","body":"hi this is a thread","created_at":"1710000002.000100","parent_vendor_message_id":"171.1"}]}]
                """
            }
            let outcome = ToolExecutionOutcome.completed(
                output: ToolExecutionOutcome.Output(format: .json, value: envelopes)
            )
            return try outcome.encodedJSON()
        }
        let adapter = PluginMessagingIngressAdapter(pluginID: "slack-connection", invoker: invoker)
        let inserted = try await adapter.pollInbox(repository: repository)
        #expect(capture.parents == ["", "171.1"])
        #expect(capture.oldests[1] == nil)
        #expect(inserted.contains(where: { $0.message.body == "hi this is a thread" }))
        let thread = try await repository.listMessagingThreads(pluginID: "slack-connection")[0]
        let replies = try await repository.listMessagingMessages(
            threadID: thread.id,
            filter: .replyThread(parentVendorMessageID: "171.1")
        )
        #expect(replies.map(\.body) == ["root", "hi this is a thread"])
    }

    @Test func pollInboxSyncsAtMostOneBehindReplyThreadPerPass() async throws {
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
        _ = try await repository.persistMessagingInbound(
            MessagingInboundRecord(
                pluginID: "slack-connection",
                vendorThreadID: "C123",
                threadTitle: "#general",
                vendorMessageID: "171.1",
                sender: "alice",
                body: "root-a",
                createdAt: Date(timeIntervalSince1970: 1_000),
                replyCount: 1
            )
        )
        _ = try await repository.persistMessagingInbound(
            MessagingInboundRecord(
                pluginID: "slack-connection",
                vendorThreadID: "C123",
                threadTitle: "#general",
                vendorMessageID: "171.3",
                sender: "alice",
                body: "root-b",
                createdAt: Date(timeIntervalSince1970: 2_000),
                replyCount: 1
            )
        )

        final class Capture: @unchecked Sendable {
            var parents: [String] = []
        }
        let capture = Capture()
        let invoker = ConnectorPluginInvoker { _, input in
            let event = try JSONDecoder().decode(PluginHopEvent.self, from: input)
            capture.parents.append(event.params?["parent_vendor_message_id"]?.stringValue ?? "")
            let envelopes = #"[{"verb":"result.emit","messages":[]}]"#
            let outcome = ToolExecutionOutcome.completed(
                output: ToolExecutionOutcome.Output(format: .json, value: envelopes)
            )
            return try outcome.encodedJSON()
        }
        let adapter = PluginMessagingIngressAdapter(pluginID: "slack-connection", invoker: invoker)
        _ = try await adapter.pollInbox(repository: repository)
        #expect(capture.parents == ["", "171.1"])
    }

    @Test func pollConversationSurfacesSlackMissingScopeAsReadPermissionError() async throws {
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
            [{"verb":"result.emit","title":"Slack blocked this thread","summary":"missing_scope"}]
            """
            let outcome = ToolExecutionOutcome.completed(
                output: ToolExecutionOutcome.Output(format: .json, value: envelopes)
            )
            return try outcome.encodedJSON()
        }
        let adapter = PluginMessagingIngressAdapter(pluginID: "slack-connection", invoker: invoker)
        do {
            _ = try await adapter.pollConversation(
                vendorThreadID: "C123",
                parentVendorMessageID: "171.1",
                repository: repository
            )
            Issue.record("Expected missing_scope to fail the reply poll")
        } catch let error as ConnectorMessagingError {
            #expect(error.localizedDescription == ConnectorReplyThreadAccessMessage.slackBlockedThread)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
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
        let oldest = try #require(capture.oldest)
        #expect(oldest.range(of: #"^\d+\.\d{6}$"#, options: .regularExpression) != nil)
        let connectors = try await repository.listMessagingConnectors()
        let listeningSince = try #require(connectors.first?.listeningSince)
        #expect(oldest == ConnectorPollCursor.unixSeconds(listeningSince))
    }

    @Test func pollInboxEmptyVendorErrorDoesNotLookLikeSuccess() async throws {
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
            [{"verb":"result.emit","messages":[],"title":"Slack message poll failed","summary":"Slack error: invalid_arguments"}]
            """
            let outcome = ToolExecutionOutcome.completed(
                output: ToolExecutionOutcome.Output(format: .json, value: envelopes)
            )
            return try outcome.encodedJSON()
        }
        let adapter = PluginMessagingIngressAdapter(pluginID: "slack-connection", invoker: invoker)
        do {
            _ = try await adapter.pollInbox(repository: repository)
            Issue.record("Expected vendor error to fail poll_inbox")
        } catch let error as ConnectorMessagingError {
            #expect(error.localizedDescription.contains("invalid_arguments"))
        }
    }

    @Test func pollInboxEmptySuccessfulListDoesNotThrow() async throws {
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
            [{"verb":"result.emit","messages":[],"title":"Slack messages","summary":"Loaded 0 messages."}]
            """
            let outcome = ToolExecutionOutcome.completed(
                output: ToolExecutionOutcome.Output(format: .json, value: envelopes)
            )
            return try outcome.encodedJSON()
        }
        let adapter = PluginMessagingIngressAdapter(pluginID: "slack-connection", invoker: invoker)
        let inserted = try await adapter.pollInbox(repository: repository)
        #expect(inserted.isEmpty)
    }

    private final class ParentCapture: @unchecked Sendable {
        var parent: String?
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
