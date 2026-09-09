import DBRepository
import Foundation
import Structure
import Testing
@testable import DerrickBackend

@Suite(.serialized) struct MessagingAgentIngressRouterTests {
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

    @Test func processInboundRoutesBareProfileTokenWithoutBotMention() async throws {
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

        final class CapturedRoute: @unchecked Sendable {
            private let lock = NSLock()
            private var route: MessagingAgentRoute?
            func store(_ value: MessagingAgentRoute) {
                lock.lock()
                route = value
                lock.unlock()
            }
            var value: MessagingAgentRoute? {
                lock.lock()
                defer { lock.unlock() }
                return route
            }
        }
        let captured = CapturedRoute()
        InProcessServiceBridges.messagingAgentRoute = { route in
            captured.store(route)
        }
        defer { InProcessServiceBridges.messagingAgentRoute = nil }

        let row = MessagingPersistResult(
            inserted: true,
            message: MessagingMessageDTO(
                threadID: "thread-1",
                vendorMessageID: "1710000002.000200",
                direction: .inbound,
                sender: "U07FKG8DV19",
                body: "$orchestrator tell me about yourself"
            ),
            thread: MessagingThreadDTO(
                id: "thread-1",
                pluginID: "slack-connection",
                vendorThreadID: "C123",
                title: "general"
            )
        )

        await MessagingAgentIngressRouter.processInbound([row], repository: repository)
        #expect(captured.value?.profileHandle == AgentProfileHandle.orchestrator)
        #expect(captured.value?.prompt == "tell me about yourself")
        #expect(captured.value?.parentVendorMessageID == "1710000002.000200")
    }

    @Test func processInboundRoutesProfileTokenAfterGreeting() async throws {
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

        final class CapturedRoute: @unchecked Sendable {
            private let lock = NSLock()
            private var route: MessagingAgentRoute?
            func store(_ value: MessagingAgentRoute) {
                lock.lock()
                route = value
                lock.unlock()
            }
            var value: MessagingAgentRoute? {
                lock.lock()
                defer { lock.unlock() }
                return route
            }
        }
        let captured = CapturedRoute()
        InProcessServiceBridges.messagingAgentRoute = { route in
            captured.store(route)
        }
        defer { InProcessServiceBridges.messagingAgentRoute = nil }

        let row = MessagingPersistResult(
            inserted: true,
            message: MessagingMessageDTO(
                threadID: "thread-1",
                vendorMessageID: "1710000004.000400",
                direction: .inbound,
                sender: "U07FKG8DV19",
                body: "hi $orchestrator how are you?"
            ),
            thread: MessagingThreadDTO(
                id: "thread-1",
                pluginID: "slack-connection",
                vendorThreadID: "C123",
                title: "general"
            )
        )

        await MessagingAgentIngressRouter.processInbound([row], repository: repository)
        #expect(captured.value?.profileHandle == AgentProfileHandle.orchestrator)
        #expect(captured.value?.prompt == "hi how are you?")
    }

    @Test func processInboundKeepsExistingThreadParent() async throws {
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

        final class CapturedRoute: @unchecked Sendable {
            private let lock = NSLock()
            private var route: MessagingAgentRoute?
            func store(_ value: MessagingAgentRoute) {
                lock.lock()
                route = value
                lock.unlock()
            }
            var value: MessagingAgentRoute? {
                lock.lock()
                defer { lock.unlock() }
                return route
            }
        }
        let captured = CapturedRoute()
        InProcessServiceBridges.messagingAgentRoute = { route in
            captured.store(route)
        }
        defer { InProcessServiceBridges.messagingAgentRoute = nil }

        let row = MessagingPersistResult(
            inserted: false,
            message: MessagingMessageDTO(
                threadID: "thread-1",
                vendorMessageID: "1710000003.000300",
                direction: .inbound,
                sender: "U07FKG8DV19",
                body: "$developer fix the build",
                parentVendorMessageID: "1710000002.000200"
            ),
            thread: MessagingThreadDTO(
                id: "thread-1",
                pluginID: "slack-connection",
                vendorThreadID: "C123",
                title: "general"
            )
        )

        await MessagingAgentIngressRouter.processInbound([row], repository: repository)
        #expect(captured.value?.profileHandle == "developer")
        #expect(captured.value?.parentVendorMessageID == "1710000002.000200")
    }

    @Test func processInboundContinuesThreadProfileWithoutDollarToken() async throws {
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
        try await repository.upsertMessagingConnector(
            MessagingConnectorDTO(pluginID: "slack-connection", displayName: "Slack")
        )
        _ = try await repository.persistMessagingInbound(
            MessagingInboundRecord(
                pluginID: "slack-connection",
                vendorThreadID: "C123",
                threadTitle: "general",
                vendorMessageID: "1710000002.000200",
                sender: "U07FKG8DV19",
                body: "$orchestrator what's today's date?"
            )
        )
        try await repository.insertMessagingMessage(
            MessagingMessageDTO(
                threadID: (try await repository.listMessagingThreads(pluginID: "slack-connection"))[0].id,
                vendorMessageID: "1710000002.000201",
                direction: .outbound,
                sender: "derrick",
                body: "[Derrick:orchestrator] Today is Tuesday.",
                parentVendorMessageID: "1710000002.000200"
            ),
            incrementUnread: false
        )
        let followUp = try await repository.persistMessagingInbound(
            MessagingInboundRecord(
                pluginID: "slack-connection",
                vendorThreadID: "C123",
                threadTitle: "general",
                vendorMessageID: "1710000002.000202",
                sender: "U07FKG8DV19",
                body: "and what day of the week is that?",
                parentVendorMessageID: "1710000002.000200"
            )
        )

        final class CapturedRoute: @unchecked Sendable {
            private let lock = NSLock()
            private var route: MessagingAgentRoute?
            func store(_ value: MessagingAgentRoute) {
                lock.lock()
                route = value
                lock.unlock()
            }
            var value: MessagingAgentRoute? {
                lock.lock()
                defer { lock.unlock() }
                return route
            }
        }
        let captured = CapturedRoute()
        InProcessServiceBridges.messagingAgentRoute = { route in
            captured.store(route)
        }
        defer { InProcessServiceBridges.messagingAgentRoute = nil }

        await MessagingAgentIngressRouter.processInbound([followUp], repository: repository)
        #expect(captured.value?.profileHandle == AgentProfileHandle.orchestrator)
        #expect(captured.value?.prompt == "and what day of the week is that?")
        #expect(captured.value?.parentVendorMessageID == "1710000002.000200")
    }

    @Test func processInboundReleasesClaimWhenRouteHandlerThrows() async throws {
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

        struct RouteFailure: Error {}
        InProcessServiceBridges.messagingAgentRoute = { _ in
            throw RouteFailure()
        }
        defer { InProcessServiceBridges.messagingAgentRoute = nil }

        let row = MessagingPersistResult(
            inserted: true,
            message: MessagingMessageDTO(
                threadID: "thread-1",
                vendorMessageID: "1710000009.000900",
                direction: .inbound,
                sender: "U07FKG8DV19",
                body: "$orchestrator ping"
            ),
            thread: MessagingThreadDTO(
                id: "thread-1",
                pluginID: "slack-connection",
                vendorThreadID: "C123",
                title: "general"
            )
        )

        await MessagingAgentIngressRouter.processInbound([row], repository: repository)
        let retryClaim = try await repository.claimMessagingAgentHandling(
            pluginID: "slack-connection",
            vendorMessageID: "1710000009.000900"
        )
        #expect(retryClaim)
    }
}
