import Foundation
import Structure
import Testing

@Suite struct HostUILibraryTests {
    @Test func bundledLibrarySatisfiesItsSchema() throws {
        try HostUILibraryStore.validateBundledLibrary()
        let ids = try HostUILibraryStore.elementIDs()
        #expect(ids.contains("screen"))
        #expect(ids.contains("sidebar"))
        #expect(ids.contains("tab_strip"))
        #expect(ids.contains("message_list"))
        #expect(ids.contains("composer"))
        #expect(ids.contains("select"))
        #expect(ids.contains("text_field"))
        #expect(ids.contains("section"))
        #expect(ids.contains("calendar"))
        #expect(ids.contains("time"))
    }

    @Test func messagingInboxExampleUsesLibraryElements() throws {
        let root = try HostUILibraryStore.messagingInbox()
        try HostUILibraryStore.validate(node: root)
        #expect(root.element == "screen")
        #expect(root.contains(element: "tab_strip"))
        #expect(root.contains(element: "sidebar"))
        #expect(root.contains(element: "optimistic_send"))
        #expect(root.first(element: "sidebar")?.configString["holds"] == "messages")
        #expect(root.first(element: "sidebar")?.contains(element: "message_list") == true)
        #expect(root.first(element: "sidebar")?.contains(element: "composer") == true)
        #expect(root.opensFirstConversation)
    }

    @Test func defaultMessagingServicesMergeOntoSlimPresent() {
        let slim = HostUINode(
            element: "screen",
            config: [
                "holds": .string("message_exchange"),
                "selection": .string("conversations"),
            ],
            children: [
                HostUINode(element: "tab_strip", bind: "conversations"),
            ]
        )
        let merged = HostUILibraryStore.withDefaultMessagingServices(slim)
        for id in HostUILibraryStore.defaultMessagingServiceIDs {
            #expect(merged.contains(element: id))
        }
    }

    @Test func bundledLibraryListsServiceElements() throws {
        let ids = try HostUILibraryStore.elementIDs()
        #expect(ids.contains("optimistic_send"))
        #expect(ids.contains("inbound_banners"))
        #expect(ids.contains("poll_refresh"))
        #expect(ids.contains("reply_pane"))
    }

    @Test func parityChecklistCoversMessagingBehaviors() {
        let cases = MessagingInboxParityChecklist.allCases
        #expect(cases.count == 10)
        #expect(cases.contains(.channelTabs))
        #expect(cases.contains(.optimisticOutbound))
        #expect(cases.contains(.inboundBannerDedupe))
        #expect(cases.contains(.pollDarwinRefresh))
        #expect(cases.contains(.replySidebar))
    }

    @Test func screenWithoutTabStripDoesNotOpenAConversation() {
        let screen = HostUINode(element: "screen", config: ["selection": .string("none")])
        #expect(screen.opensFirstConversation == false)
    }

    @Test func presentPayloadDecodesRoot() throws {
        let payload: [String: PluginJSON] = [
            "root": .object([
                "element": .string("screen"),
                "id": .string("inbox"),
                "children": .array([
                    .object([
                        "element": .string("tab_strip"),
                        "bind": .string("conversations"),
                    ]),
                ]),
            ]),
        ]
        let node = try HostUILibraryStore.node(fromPresentPayload: payload)
        #expect(node.id == "inbox")
        #expect(node.contains(element: "tab_strip"))
    }

    @Test func presentPayloadRejectsUnknownElement() {
        let payload: [String: PluginJSON] = [
            "root": .object(["element": .string("slack_channel_list")]),
        ]
        #expect(throws: HostUILibraryError.self) {
            try HostUILibraryStore.node(fromPresentPayload: payload)
        }
    }

    @Test func presentStorePersistsThroughPersister() async throws {
        final class MemoryPersister: HostUIPresentPersisting, @unchecked Sendable {
            var roots: [String: HostUINode] = [:]
            func saveHostUIPresent(pluginID: String, root: HostUINode) async throws {
                roots[pluginID] = root
            }
            func loadHostUIPresent(pluginID: String) async throws -> HostUINode? {
                roots[pluginID]
            }
        }
        let persister = MemoryPersister()
        let store = HostUIPresentStore()
        await store.configure(persister: persister)
        let root = HostUINode(element: "screen", id: "saved", children: [
            HostUINode(element: "calendar", id: "day"),
        ])
        await store.record(pluginID: "p1", root: root)
        #expect(persister.roots["p1"]?.id == "saved")

        let cold = HostUIPresentStore()
        await cold.configure(persister: persister)
        let loaded = await cold.root(pluginID: "p1")
        #expect(loaded?.id == "saved")
        #expect(loaded?.contains(element: "calendar") == true)
    }

    @Test func envelopeListAcceptsUIPresentRoot() throws {
        let json = """
        [{"verb":"ui.present","root":{"element":"screen","id":"inbox","children":[{"element":"composer","bind":"selected_conversation"}]}}]
        """
        try GuestContractValidation.validateEnvelopeListJSON(Data(json.utf8))
    }
}
