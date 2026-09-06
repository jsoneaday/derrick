import DBRepository
import DerrickBackend
import Foundation
import Structure

@main
enum SlackConnectorLiveHarnessMain {
    static func main() async {
        do {
            try await run()
            fputs("SlackConnectorLiveHarness: SUCCESS\n", stderr)
        } catch {
            fputs("SlackConnectorLiveHarness: FAILED — \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        let env = try await LiveHarnessEnvironment.bootstrap()
        try await env.cleanupPlugin()
        try env.ensureSlackCredentials()

        _ = try await env.buildSendAndReceiveConnector()
        try await env.registerConnector()

        let adapter = PluginMessagingIngressAdapter(
            pluginID: LiveHarnessEnvironment.pluginID,
            invoker: env.makeInvoker()
        )
        try await adapter.bootstrap(repository: env.repository)

        let channelID = try await env.resolveSlackChannelID()
        fputs("[live] target channel \(channelID)\n", stderr)

        let threads = try await env.repository.listMessagingThreads(
            pluginID: LiveHarnessEnvironment.pluginID
        )
        guard let thread = threads.first(where: { $0.vendorThreadID == channelID }) else {
            let titles = threads.map { "\($0.title)=\($0.vendorThreadID)" }.joined(separator: ", ")
            throw LiveHarnessError.messagingFailed(
                "sync_threads did not include channel \(channelID). Threads: \(titles)"
            )
        }

        let marker = "Derrick live verify — please reply to this message (\(UUID().uuidString.prefix(8)))"
        try await adapter.sendMessage(
            vendorThreadID: thread.vendorThreadID,
            text: marker,
            threadID: thread.id,
            repository: env.repository
        )
        fputs("[live] sent outbound: \(marker)\n", stderr)

        let pollSeconds = Int(ProcessInfo.processInfo.environment["LIVE_POLL_SECONDS"] ?? "120") ?? 120
        let deadline = Date().addingTimeInterval(TimeInterval(pollSeconds))
        fputs("[live] polling up to \(pollSeconds)s for your Slack reply…\n", stderr)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            let inserted = try await adapter.pollInbox(repository: env.repository)
            let inbound = try await env.repository.listMessagingMessages(threadID: thread.id, limit: 20)
                .filter {
                    $0.direction == .inbound
                        && $0.createdAt > Date().addingTimeInterval(-TimeInterval(pollSeconds + 30))
                }
            if let reply = inbound.last(where: { !$0.body.contains(marker) }) {
                fputs("[live] received inbound from \(reply.sender): \(reply.body)\n", stderr)
                return
            }
            if !inserted.isEmpty {
                fputs("[live] poll inserted \(inserted.count) row(s), still waiting for your reply…\n", stderr)
            }
        }
        throw LiveHarnessError.messagingFailed(
            "No inbound reply received within \(pollSeconds)s. Outbound send succeeded — reply in Slack and open Messaging in Derrick."
        )
    }
}
