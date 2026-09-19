import HostUI
import Testing

@Suite struct HostUIElementIDTests {
    @Test func serviceIdsAreMarked() {
        #expect(HostUIElementID.optimisticSend.isService)
        #expect(HostUIElementID.messageList.isService == false)
    }
}
