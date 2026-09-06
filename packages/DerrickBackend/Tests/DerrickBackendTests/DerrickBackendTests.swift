import Foundation
@testable import DerrickBackend
import Structure
import Testing

@Suite struct DerrickBackendTests {
    @Test func notificationRequestRoundTrip() throws {
        let request = UserNotificationRequest(
            kind: .jobResult,
            title: "Job finished",
            body: "hello",
            userInfo: [UserNotificationUserInfoKey.jobResultID.rawValue: "abc"]
        )
        let data = try DerrickDaemonXPCCodec.encodeNotificationRequest(request)
        let decoded = try DerrickDaemonXPCCodec.decodeNotificationRequest(data)
        #expect(decoded.kind == .jobResult)
        #expect(decoded.title == "Job finished")
        #expect(decoded.userInfo[UserNotificationUserInfoKey.jobResultID.rawValue] == "abc")
    }

    @Test func hitlApprovalNotificationRequestRoundTrip() throws {
        let request = UserNotificationRequest(
            kind: .hitlApproval,
            title: "Approval needed",
            body: "Tap to approve",
            userInfo: [UserNotificationUserInfoKey.approvalID.rawValue: "approval-1"]
        )
        let data = try DerrickDaemonXPCCodec.encodeNotificationRequest(request)
        let decoded = try DerrickDaemonXPCCodec.decodeNotificationRequest(data)
        #expect(decoded.kind == .hitlApproval)
        #expect(decoded.userInfo[UserNotificationUserInfoKey.approvalID.rawValue] == "approval-1")
    }

    @Test func messagingIngressSignalNamesAreStable() {
        #expect(DerrickMessagingIngressSignal.darwinName == "derrickd.pollMessagingIngress")
        #expect(DerrickMessagingInboundSignal.darwinName == "derrick.ui.messagingInbound")
    }

    @Test func messagingInboundNotifierBuildsOneRequestPerThread() {
        let general = MessagingThreadDTO(
            id: "thread-general",
            pluginID: "slack-bot",
            vendorThreadID: "C1",
            title: "#general"
        )
        let random = MessagingThreadDTO(
            id: "thread-random",
            pluginID: "slack-bot",
            vendorThreadID: "C2",
            title: "#random"
        )
        let muted = MessagingThreadDTO(
            id: "thread-muted",
            pluginID: "slack-bot",
            vendorThreadID: "C3",
            title: "#muted",
            muted: true
        )
        let rows = [
            MessagingPersistResult(
                inserted: true,
                message: MessagingMessageDTO(
                    threadID: general.id,
                    direction: .inbound,
                    sender: "ada",
                    body: "hello",
                    createdAt: Date(timeIntervalSince1970: 1)
                ),
                thread: general
            ),
            MessagingPersistResult(
                inserted: true,
                message: MessagingMessageDTO(
                    threadID: general.id,
                    direction: .inbound,
                    sender: "grace",
                    body: "second",
                    createdAt: Date(timeIntervalSince1970: 2)
                ),
                thread: general
            ),
            MessagingPersistResult(
                inserted: true,
                message: MessagingMessageDTO(
                    threadID: random.id,
                    direction: .inbound,
                    sender: "bob",
                    body: "hi"
                ),
                thread: random
            ),
            MessagingPersistResult(
                inserted: true,
                message: MessagingMessageDTO(
                    threadID: muted.id,
                    direction: .inbound,
                    sender: "eve",
                    body: "secret"
                ),
                thread: muted
            ),
            MessagingPersistResult(
                inserted: false,
                message: MessagingMessageDTO(
                    threadID: random.id,
                    direction: .inbound,
                    sender: "bob",
                    body: "duplicate"
                ),
                thread: random
            ),
        ]
        let requests = MessagingInboundNotifier.notificationRequests(from: rows)
        #expect(requests.count == 2)
        let generalRequest = requests.first { $0.userInfo[UserNotificationUserInfoKey.threadID.rawValue] == general.id }
        let randomRequest = requests.first { $0.userInfo[UserNotificationUserInfoKey.threadID.rawValue] == random.id }
        #expect(generalRequest?.kind == .messagingMessage)
        #expect(generalRequest?.title == "#general")
        #expect(generalRequest?.body.contains("2 new messages") == true)
        #expect(generalRequest?.body.contains("grace: second") == true)
        #expect(randomRequest?.title == "#random")
        #expect(randomRequest?.body == "bob: hi")
        #expect(!requests.contains { $0.userInfo[UserNotificationUserInfoKey.threadID.rawValue] == muted.id })
    }

    @Test func messagingInboundNotifierSkipsWhenUIIsInteractive() async {
        let thread = MessagingThreadDTO(
            id: "thread-general",
            pluginID: "slack-bot",
            vendorThreadID: "C1",
            title: "#general"
        )
        let rows = [
            MessagingPersistResult(
                inserted: true,
                message: MessagingMessageDTO(
                    threadID: thread.id,
                    direction: .inbound,
                    sender: "ada",
                    body: "hello"
                ),
                thread: thread
            )
        ]
        #expect(!MessagingInboundNotifier.notificationRequests(from: rows).isEmpty)
        await MessagingInboundNotifier.notifyNewInbound(rows, uiIsInteractive: true)
    }
}
