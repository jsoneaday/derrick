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
        let root = node.element == HostUIElementID.screen.rawValue ? node : HostUINode(
            element: HostUIElementID.screen.rawValue,
            children: [node]
        )
        messagingScreen(root)
    }

    @ViewBuilder
    private func messagingScreen(_ root: HostUINode) -> some View {
        let kids = root.children ?? []
        let tabs = kids.filter { $0.element == HostUIElementID.tabStrip.rawValue }
        let sidebars = kids.filter { $0.element == HostUIElementID.sidebar.rawValue }
        let main = kids.filter {
            $0.element != HostUIElementID.tabStrip.rawValue
                && $0.element != HostUIElementID.sidebar.rawValue
                && HostUIElementID(rawValue: $0.element)?.isService != true
        }

        ZStack(alignment: .top) {
            HostUIScreen {
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
            if bindings.hasService(.inboundBanners),
               let banner = bindings.inboundBanner,
               !banner.isEmpty {
                bannerToast(banner)
                    .padding(.top, 10)
            }
        }
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
                Spacer()
                Button(action: bindings.onCloseReplyThread) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            if let warning = bindings.replyThreadWarning, !warning.isEmpty {
                Text(warning)
                    .font(.caption)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array((sidebar.children ?? []).enumerated()), id: \.offset) { _, child in
                nodeContent(child, isThread: true)
            }
        }
    }

    @ViewBuilder
    private func nodeContent(_ node: HostUINode, isThread: Bool) -> some View {
        switch HostUIElementID(rawValue: node.element) {
        case .messageList:
            messageList(bind: node.bind, isThread: isThread)
        case .composer:
            composer(bind: node.bind, isThread: isThread)
        case .text:
            HostUIText(node.configString["text"] ?? "")
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
                    // AnyView breaks the recursive opaque-return cycle for nested sections.
                    AnyView(nodeContent(child, isThread: isThread))
                }
            }
            .padding(.horizontal)
        case .optimisticSend, .inboundBanners, .pollRefresh, .replyPane, .tabStrip, .sidebar, .screen, .select, .table, .message:
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
}
