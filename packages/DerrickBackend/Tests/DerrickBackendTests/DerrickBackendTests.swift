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
}
