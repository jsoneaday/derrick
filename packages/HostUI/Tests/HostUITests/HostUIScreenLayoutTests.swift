import HostUI
import Structure
import Testing

@Suite struct HostUIScreenLayoutTests {
    @Test func messageExchangeUsesInboxChrome() throws {
        let inbox = try HostUILibraryStore.messagingInbox()
        #expect(HostUIScreenLayout.isMessageExchange(inbox))
        #expect(HostUIScreenLayout.tabStripNodes(in: inbox).count == 1)
        #expect(HostUIScreenLayout.sidebarNodes(in: inbox).count == 1)
        #expect(
            HostUIScreenLayout.mainNodes(in: inbox).map(\.element)
                == [HostUIElementID.messageList.rawValue, HostUIElementID.composer.rawValue]
        )
    }

    @Test func arbitraryScreenDoesNotUseInboxChrome() {
        let form = HostUINode(
            element: "screen",
            config: ["holds": .string("arbitrary")],
            children: [
                HostUINode(element: "calendar", id: "day"),
                HostUINode(element: "time", id: "at"),
            ]
        )
        #expect(HostUIScreenLayout.isMessageExchange(form) == false)
        #expect(HostUIScreenLayout.tabStripNodes(in: form).isEmpty)
        #expect(HostUIScreenLayout.mainNodes(in: form).map(\.element) == ["calendar", "time"])
    }

    @Test func nonScreenNodesBecomeArbitraryScreens() {
        let calendar = HostUINode(element: "calendar", id: "day")
        let root = HostUIScreenLayout.normalized(calendar)
        #expect(root.element == "screen")
        #expect(HostUIScreenLayout.isMessageExchange(root) == false)
        #expect(HostUIScreenLayout.visibleChildren(of: root).map(\.element) == ["calendar"])
    }

    @Test func servicesAreNotVisibleChildren() {
        let root = HostUINode(
            element: "screen",
            config: ["holds": .string("message_exchange")],
            children: [
                HostUINode(element: "optimistic_send"),
                HostUINode(element: "message_list", bind: "selected_conversation"),
            ]
        )
        #expect(HostUIScreenLayout.visibleChildren(of: root).map(\.element) == ["message_list"])
    }
}
