import DBRepository
import Foundation
import Structure
import Testing
@testable import DerrickBackend

@Suite struct MessagingAgentIngressRouterTests {
    @Test func processInboundSkipsMessagesWithoutBotMention() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = DBRepository(
            configuration: DBRepositoryConfiguration(
                applicationName: "ui",
                databaseName: "derrick",
                databaseDirectoryURL: directory,
                username: "app-user",
                password: "app-secret"
            )
        )
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")

        final class RouteCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func increment() {
                lock.lock()
                count += 1
                lock.unlock()
            }
            var value: Int {
                lock.lock()
                defer { lock.unlock() }
                return count
            }
        }
        let counter = RouteCounter()
        InProcessServiceBridges.messagingAgentRoute = { _ in
            counter.increment()
        }
        defer { InProcessServiceBridges.messagingAgentRoute = nil }

        let row = MessagingPersistResult(
            inserted: true,
            message: MessagingMessageDTO(
                threadID: "thread-1",
                vendorMessageID: "1710000001.000100",
                direction: .inbound,
                sender: "U123",
                body: "hello without mention"
            ),
            thread: MessagingThreadDTO(
                id: "thread-1",
                pluginID: "slack-connection",
                vendorThreadID: "C123",
                title: "general"
            )
        )

        await MessagingAgentIngressRouter.processInbound([row], repository: repository)
        #expect(counter.value == 0)
    }
}
