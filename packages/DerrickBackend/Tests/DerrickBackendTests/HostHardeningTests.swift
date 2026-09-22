import DBRepository
import Foundation
import Plugin
import Structure
import Testing
@testable import DerrickBackend

@Suite struct HostSecretBoundaryTests {
    @Test func connectorInvokeDoesNotCarryHostCredentials() throws {
        setenv("OPENAI_API_KEY", "sk-host-boundary", 1)
        setenv("GEMINI_API_KEY", "gemini-host-boundary", 1)
        defer {
            unsetenv("OPENAI_API_KEY")
            unsetenv("GEMINI_API_KEY")
        }

        let input = try ConnectorMessagingHopBuilder.inputData(
            operation: .sendMessage,
            params: [
                "vendor_thread_id": .string("C1"),
                "text": .string("hello"),
            ]
        )
        let wrapped = try ConnectorMessagingBridgeEncoding.pluginInvokeArgumentsJSON(
            pluginID: "connector-1",
            input: input
        )
        let lowered = wrapped.lowercased()
        #expect(!lowered.contains("authorization"))
        #expect(!wrapped.contains("sk-host-boundary"))
        #expect(!wrapped.contains("gemini-host-boundary"))
        #expect(!wrapped.contains("OPENAI_API_KEY"))
        #expect(!wrapped.contains("GEMINI_API_KEY"))
    }

    @Test func hostMessagingSourcesDoNotCallSlack() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let roots = [
            root.appendingPathComponent("packages/DerrickBackend/Sources"),
            root.appendingPathComponent("packages/HostUI/Sources"),
            root.appendingPathComponent("ui/ui/Messaging"),
        ]
        let forbidden = ["api.slack.com", "slack.com/api", "hooks.slack.com"]
        var hits: [String] = []
        for directory in roots {
            for file in swiftFiles(in: directory) {
                let text = try String(contentsOf: file, encoding: .utf8)
                for needle in forbidden where text.contains(needle) {
                    hits.append("\(file.lastPathComponent): \(needle)")
                }
            }
        }
        #expect(hits.isEmpty)
    }
}

@Suite struct MessagingSendInboundConcurrencyTests {
    @Test func overlappingSendAndInboundPollKeepBothRows() async throws {
        let repository = try makeRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")
        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "connector-1", displayName: "Connector")
        )
        let thread = MessagingThreadDTO(
            pluginID: "connector-1",
            vendorThreadID: "C1",
            title: "general"
        )
        try await repository.upsertMessagingThread(thread)

        let gate = PeerGate()
        let invoker = ConnectorPluginInvoker { _, input in
            let text = String(decoding: input, as: UTF8.self)
            if text.contains("send_message") {
                await gate.markSendEntered()
                await gate.waitUntilPollStarted()
                let envelopes = """
                [{"verb":"result.emit","sent_message":{"vendor_message_id":"42.0","created_at":"1710000001.000100"}}]
                """
                let outcome = ToolExecutionOutcome.completed(
                    output: ToolExecutionOutcome.Output(format: .json, value: envelopes)
                )
                return try outcome.encodedJSON()
            }
            await gate.markPollStarted()
            let envelopes = """
            [{"verb":"result.emit","messages":[{"vendor_thread_id":"C1","vendor_message_id":"9.9","direction":"inbound","sender":"ada","body":"inbound hello","created_at":"1710000000.000100"}]}]
            """
            let outcome = ToolExecutionOutcome.completed(
                output: ToolExecutionOutcome.Output(format: .json, value: envelopes)
            )
            return try outcome.encodedJSON()
        }
        let adapter = PluginMessagingIngressAdapter(pluginID: "connector-1", invoker: invoker)

        async let send: Void = adapter.sendMessage(
            vendorThreadID: "C1",
            text: "outbound hello",
            threadID: thread.id,
            repository: repository
        )
        await gate.waitUntilSendEntered()
        _ = try await adapter.pollInbox(repository: repository)
        try await send

        let messages = try await repository.listMessagingMessages(threadID: thread.id, limit: 10)
        #expect(Set(messages.map(\.body)) == ["outbound hello", "inbound hello"])
        #expect(messages.first { $0.body == "outbound hello" }?.vendorMessageID == "42.0")
        #expect(messages.first { $0.body == "inbound hello" }?.direction == .inbound)
    }
}

private actor PeerGate {
    private var sendEntered = false
    private var pollStarted = false
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []
    private var pollWaiters: [CheckedContinuation<Void, Never>] = []

    func markSendEntered() {
        sendEntered = true
        let waiters = pollWaiters
        pollWaiters = []
        waiters.forEach { $0.resume() }
    }

    func waitUntilSendEntered() async {
        if sendEntered { return }
        await withCheckedContinuation { pollWaiters.append($0) }
    }

    func markPollStarted() {
        pollStarted = true
        let waiters = sendWaiters
        sendWaiters = []
        waiters.forEach { $0.resume() }
    }

    func waitUntilPollStarted() async {
        if pollStarted { return }
        await withCheckedContinuation { sendWaiters.append($0) }
    }
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

private func swiftFiles(in directory: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: nil
    ) else {
        return []
    }
    return enumerator.compactMap { item in
        guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
        return url
    }
}
