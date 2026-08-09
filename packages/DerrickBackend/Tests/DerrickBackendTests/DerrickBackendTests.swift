import Foundation
@testable import DerrickBackend
import ServiceContracts
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
}
