import Structure
import SwiftUI

/// Maps a validated `HostUINode` tree onto HostUI controls and activates declared services.
public struct HostUINodeView: View {
    private let node: HostUINode
    private let bindings: HostUINodeBindings

    public init(node: HostUINode, bindings: HostUINodeBindings) {
        self.node = node
        self.bindings = bindings
    }

    public var body: some View {
        let root = HostUIScreenLayout.normalized(node)
        ZStack(alignment: .top) {
            HostUIScreen {
                if HostUIScreenLayout.isMessageExchange(root) {
                    messageExchangeChrome(root)
                } else {
                    genericStack(root)
                }
            }
            if bindings.hasService(.inboundBanners),
               let banner = bindings.inboundBanner,
               !banner.isEmpty {
                bannerToast(banner)
                    .padding(.top, 10)
            }
        }
    }

    @ViewBuilder
    private func messageExchangeChrome(_ root: HostUINode) -> some View {
        let tabs = HostUIScreenLayout.tabStripNodes(in: root)
        let sidebars = replySidebars(in: root)
        let main = HostUIScreenLayout.mainNodes(in: root)

        VStack(spacing: 0) {
            if !tabs.isEmpty, !bindings.tabs.isEmpty {
                HostUITabStrip(
                    tabs: bindings.tabs,
                    selectedID: bindings.selectedTabID,
                    onSelect: bindings.onSelectTab
                )
            }
            HStack(spacing: 0) {
                mainColumn(main)
                if shouldShowSidebar(sidebars) {
                    Divider()
                    ForEach(Array(sidebars.enumerated()), id: \.offset) { _, sidebar in
                        HostUISidebar {
                            sidebarColumn(sidebar)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func genericStack(_ root: HostUINode) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(HostUIScreenLayout.visibleChildren(of: root).enumerated()), id: \.offset) { _, child in
                if child.element == HostUIElementID.sidebar.rawValue {
                    if shouldShowSidebar([child]) {
                        HostUISidebar {
                            sidebarColumn(child)
                        }
                    }
                } else {
                    nodeContent(child, isThread: false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Sidebar nodes, or a host reply pane when `reply_pane` is declared without a sidebar child.
    private func replySidebars(in root: HostUINode) -> [HostUINode] {
        let declared = HostUIScreenLayout.sidebarNodes(in: root)
        if !declared.isEmpty { return declared }
        guard bindings.hasService(.replyPane) else { return [] }
        return [
            HostUINode(
                element: HostUIElementID.sidebar.rawValue,
                config: [
                    "holds": .string("messages"),
                    "visible_when": .string("reply_thread"),
                ]
            ),
        ]
    }

    private func shouldShowSidebar(_ sidebars: [HostUINode]) -> Bool {
        guard let sidebar = sidebars.first else { return false }
        let when = sidebar.configString["visible_when"] ?? "reply_thread"
        if when == "always" { return true }
        // Show whenever a reply thread is open; reply_pane is advisory for guest trees.
        return bindings.isViewingReplyThread
    }

    @ViewBuilder
    private func mainColumn(_ nodes: [HostUINode]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { _, child in
                nodeContent(child, isThread: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func sidebarColumn(_ sidebar: HostUINode) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(bindings.replyThreadTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button(action: bindings.onCloseReplyThread) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close thread")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            if let warning = bindings.replyThreadWarning, !warning.isEmpty {
                Text(warning)
                    .font(.caption)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Host owns reply chrome when holds=messages (default). Guest children
            // are only used for arbitrary sidebars.
            if sidebar.configString["holds"] == "arbitrary" {
                ForEach(Array((sidebar.children ?? []).enumerated()), id: \.offset) { _, child in
                    nodeContent(child, isThread: true)
                }
            } else {
                messageList(bind: "selected_thread", isThread: true)
                if let work = bindings.threadAgentWorkStatus, !work.isEmpty {
                    HostUIAgentWorkIndicator(status: work)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                composer(bind: "selected_thread", isThread: true)
                    .layoutPriority(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func nodeContent(_ node: HostUINode, isThread: Bool) -> some View {
        switch HostUIElementID(rawValue: node.element) {
        case .messageList:
            messageList(bind: node.bind, isThread: isThread)
        case .composer:
            composer(bind: node.bind, isThread: isThread)
        case .tabStrip:
            if !bindings.tabs.isEmpty {
                HostUITabStrip(
                    tabs: bindings.tabs,
                    selectedID: bindings.selectedTabID,
                    onSelect: bindings.onSelectTab
                )
            }
        case .select:
            HostUISelect(
                options: node.bind == "conversations" ? bindings.tabs : [],
                selectedID: bindings.selectedTabID,
                placeholder: node.configString["placeholder"] ?? "Choose",
                onSelect: bindings.onSelectTab
            )
            .padding()
        case .table:
            HostUITable(rows: tableRows(from: node))
                .padding()
        case .text:
            HostUIMarkdownText(node.configString["text"] ?? "", fontSize: 13)
                .padding()
        case .button:
            HostUIButton(node.configString["label"] ?? "Button") {}
                .padding()
        case .textField:
            HostUITextField(node.configString["placeholder"] ?? "", text: .constant(""))
                .padding()
        case .calendar:
            HostUICalendar(label: node.configString["label"], date: .constant(Date()))
                .padding()
        case .time:
            HostUITime(label: node.configString["label"], date: .constant(Date()))
                .padding()
        case .section:
            HostUISection(title: node.configString["title"]) {
                ForEach(Array((node.children ?? []).enumerated()), id: \.offset) { _, child in
                    AnyView(nodeContent(child, isThread: isThread))
                }
            }
            .padding(.horizontal)
        case .optimisticSend, .inboundBanners, .pollRefresh, .replyPane, .sidebar, .screen, .message:
            EmptyView()
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func messageList(bind: String?, isThread: Bool) -> some View {
        let rows = isThread || bind == "selected_thread"
            ? bindings.threadMessages
            : bindings.channelMessages
        ZStack(alignment: .bottom) {
            HostUIMessageList(
                rows: rows,
                onOpenThread: isThread ? nil : bindings.onOpenThread,
                onNearBottomChange: isThread ? nil : bindings.onNearBottomChange,
                onLoadOlder: isThread ? nil : bindings.onLoadOlder,
                scrollToBottomToken: bindings.scrollToBottomToken
            )
            if !isThread, bindings.showJumpToLatest || bindings.showNewMessagesPill {
                Button(action: bindings.onJumpToLatest) {
                    Text(bindings.showNewMessagesPill ? "New messages" : "Jump to latest")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.white, in: Capsule())
                        .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 1)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 0)
    }

    @ViewBuilder
    private func composer(bind: String?, isThread: Bool) -> some View {
        let thread = isThread || bind == "selected_thread"
        HostUIComposer(
            text: thread ? bindings.threadDraft : bindings.channelDraft,
            placeholder: thread ? "Reply" : "Message",
            isSending: bindings.isSending,
            canSend: thread ? bindings.canSendThread : bindings.canSendChannel,
            onSubmit: thread ? bindings.onSubmitThread : bindings.onSubmitChannel
        )
    }

    private func bannerToast(_ text: String) -> some View {
        Button(action: bindings.onBannerTap) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.fill")
                    .foregroundStyle(Color(red: 0.176, green: 0.286, blue: 0.576))
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Color(red: 248.0 / 255.0, green: 248.0 / 255.0, blue: 246.0 / 255.0),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color(red: 0.176, green: 0.286, blue: 0.576).opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
    }

    private func tableRows(from node: HostUINode) -> [String] {
        guard let rows = node.config?["rows"]?.arrayValue else { return [] }
        return rows.compactMap(\.stringValue)
    }
}

#Preview("Reply pane filled") {
    HostUIInboxPreviewHost(emptyGuestSidebar: false)
        .frame(width: 1100, height: 720)
}

#Preview("Reply pane empty guest sidebar") {
    HostUIInboxPreviewHost(emptyGuestSidebar: true)
        .frame(width: 1100, height: 720)
}

private struct HostUIInboxPreviewHost: View {
    var emptyGuestSidebar: Bool
    @State private var channelDraft = ""
    @State private var threadDraft = ""

    var body: some View {
        HostUINodeView(node: root, bindings: bindings)
            .background(Color(red: 248.0 / 255.0, green: 244.0 / 255.0, blue: 240.0 / 255.0))
    }

    private var root: HostUINode {
        if emptyGuestSidebar {
            return HostUINode(
                element: "screen",
                config: ["holds": .string("message_exchange")],
                children: [
                    HostUINode(element: "tab_strip", bind: "conversations"),
                    HostUINode(element: "message_list", bind: "selected_conversation"),
                    HostUINode(element: "composer", bind: "selected_conversation"),
                    HostUINode(
                        element: "sidebar",
                        config: [
                            "holds": .string("messages"),
                            "visible_when": .string("reply_thread"),
                        ]
                    ),
                ]
            )
        }
        return (try? HostUILibraryStore.messagingInbox()) ?? HostUINode(element: "screen")
    }

    private var bindings: HostUINodeBindings {
        HostUINodeBindings(
            tabs: [HostUITabItem(id: "g", title: "general")],
            selectedTabID: "g",
            channelMessages: [
                HostUIMessageRow(
                    id: "p",
                    sender: "David Choi (jsoneaday)",
                    body: "$orchestrator weather in 07647",
                    outbound: false,
                    replyCount: 1,
                    replyPreview: "Searching the web…",
                    showsReplyAction: true
                )
            ],
            threadMessages: [
                HostUIMessageRow(
                    id: "p",
                    sender: "David Choi (jsoneaday)",
                    body: "$orchestrator weather in 07647",
                    outbound: false
                ),
                HostUIMessageRow(
                    id: "r",
                    sender: "derrick",
                    body: """
                    [Derrick:orchestrator] Searching the web…

                    In **Northvale, NJ 07647**, Weather Underground reported **62°F** at **7:27 AM EDT on September 19, 2026**. Its listed daily temp **71°F / 63°F**.

                    [View current conditions on Weather Underground](https://www.wunderground.com)
                    """,
                    outbound: true
                )
            ],
            channelDraft: $channelDraft,
            threadDraft: $threadDraft,
            isViewingReplyThread: true,
            replyThreadTitle: "$orchestrator weather in 07647"
        )
    }
}
