import HostUI
import Structure
import SwiftUI

/// Renders a saved `HostUINode` tree for messaging using the shared HostUI kit.
struct MessagingHostUISurface: View {
    @ObservedObject var store: MessagingStore
    @Binding var draft: String
    @Binding var threadDraft: String
    var onSubmitChannel: () -> Void
    var onSubmitThread: () -> Void
    @ObservedObject private var agentProfiles = AgentProfileStore.shared

    var body: some View {
        let root = store.hostUIRoot
        let kids = root.element == HostUIElementID.screen.rawValue ? (root.children ?? []) : [root]
        let tabs = kids.filter { $0.element == HostUIElementID.tabStrip.rawValue }
        let sidebars = kids.filter { $0.element == HostUIElementID.sidebar.rawValue }
        let main = kids.filter {
            $0.element != HostUIElementID.tabStrip.rawValue
                && $0.element != HostUIElementID.sidebar.rawValue
        }

        HostUIScreen {
            VStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { _, node in
                    tabStrip(node)
                }
                HStack(spacing: 0) {
                    mainColumn(main)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    ForEach(Array(sidebars.enumerated()), id: \.offset) { _, node in
                        if isSidebarVisible(node) {
                            Divider()
                            HostUISidebar {
                                sidebarColumn(node)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tabStrip(_ node: HostUINode) -> some View {
        HostUITabStrip(
            tabs: store.tabs.map {
                HostUITabItem(
                    id: $0.id,
                    title: $0.title,
                    unreadCount: $0.unreadCount,
                    muted: $0.muted
                )
            },
            selectedID: store.selectedThreadID,
            onSelect: { id in
                Task { await store.selectThread(id: id) }
            }
        )
        .accessibilityIdentifier(node.id ?? node.bind ?? "tab_strip")
    }

    @ViewBuilder
    private func mainColumn(_ nodes: [HostUINode]) -> some View {
        VStack(spacing: 0) {
            channelHeader
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
                        mainChild(node)
                    }
                }
                if store.showJumpToLatest || store.showNewMessagesPill {
                    Button {
                        Task { await store.jumpToLatest() }
                    } label: {
                        Text(store.showNewMessagesPill ? "New messages" : "Jump to latest")
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
        }
    }

    @ViewBuilder
    private func mainChild(_ node: HostUINode) -> some View {
        switch HostUIElementID(rawValue: node.element) {
        case .messageList:
            messageList(for: node, isThread: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .composer:
            composer(for: node, isThread: false)
        default:
            HostUINodeView(node: node, bindings: makeBindings())
        }
    }

    @ViewBuilder
    private func sidebarColumn(_ node: HostUINode) -> some View {
        VStack(spacing: 0) {
            threadHeader
            if let warning = store.replyThreadWarning, !warning.isEmpty {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.orange.opacity(0.14))
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            ForEach(Array((node.children ?? []).enumerated()), id: \.offset) { _, child in
                sidebarChild(child)
            }
        }
        .background(Color.white.opacity(0.55))
    }

    @ViewBuilder
    private func sidebarChild(_ node: HostUINode) -> some View {
        switch HostUIElementID(rawValue: node.element) {
        case .messageList:
            messageList(for: node, isThread: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .composer:
            composer(for: node, isThread: true)
        default:
            HostUINodeView(node: node, bindings: makeBindings())
        }
    }

    @ViewBuilder
    private func messageList(for node: HostUINode, isThread: Bool) -> some View {
        let messages = isThread ? store.visibleReplyMessages : store.visibleMessages
        let rows = messages.map { message in
            HostUIMessageRow(
                id: message.id,
                sender: message.sender,
                body: message.body,
                outbound: message.direction == .outbound,
                replyCount: message.replyCount,
                replyPreview: message.vendorMessageID.flatMap { store.lastReplyPreviewByParentID[$0] },
                showsReplyAction: !isThread && message.vendorMessageID != nil
            )
        }
        HostUIMessageList(
            rows: rows,
            bottomID: isThread ? "thread-scroll-bottom" : "channel-scroll-bottom",
            loadsOlder: !isThread,
            scrollToBottomToken: store.scrollToBottomToken,
            scrollAnchorID: isThread ? nil : store.scrollAnchorID,
            onLoadOlder: {
                Task { await store.loadOlderIfNeeded() }
            },
            onNearBottomChange: { near in
                store.setNearBottom(near)
            }
        ) { row in
            if let message = messages.first(where: { $0.id == row.id }) {
                MessagingBubble(
                    message: message,
                    showsReplyAction: row.showsReplyAction,
                    lastReplyPreview: row.replyPreview
                ) {
                    if let parent = message.vendorMessageID {
                        Task { await store.openReplyThread(parentVendorMessageID: parent) }
                    }
                }
            } else {
                HostUIMessage(sender: row.sender, body: row.body, outbound: row.outbound)
            }
        }
        .padding(.horizontal, isThread ? 0 : 8)
        .accessibilityIdentifier(node.id ?? node.bind ?? "message_list")
    }

    @ViewBuilder
    private func composer(for node: HostUINode, isThread: Bool) -> some View {
        HostUIComposer(
            placeholder: isThread ? "Reply" : "Message",
            sendTitle: isThread ? "Reply" : "Send",
            text: isThread ? $threadDraft : $draft,
            isSending: store.isSending,
            canSend: store.canSendInSelectedThread && !(isThread ? threadDraft : draft)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            onSend: isThread ? onSubmitThread : onSubmitChannel
        )
        .padding(.horizontal, isThread ? 16 : 24)
        .padding(.bottom, 16)
        .accessibilityIdentifier(node.id ?? node.bind ?? "composer")
    }

    private func isSidebarVisible(_ node: HostUINode) -> Bool {
        let when = node.configString["visible_when"] ?? "reply_thread"
        if when == "always" { return true }
        return store.isViewingReplyThread
    }

    private func makeBindings() -> HostUINodeBindings {
        HostUINodeBindings(
            strings: [
                "compose": $draft,
                "reply": $threadDraft,
                "selected_conversation": $draft,
                "selected_thread": $threadDraft,
            ],
            actions: [
                "compose": onSubmitChannel,
                "reply": onSubmitThread,
                "selected_conversation": onSubmitChannel,
                "selected_thread": onSubmitThread,
            ],
            canSendFlags: [
                "compose": store.canSendInSelectedThread,
                "reply": store.canSendInSelectedThread,
                "selected_conversation": store.canSendInSelectedThread,
                "selected_thread": store.canSendInSelectedThread,
            ],
            isSendingFlags: [
                "compose": store.isSending,
                "reply": store.isSending,
                "selected_conversation": store.isSending,
                "selected_thread": store.isSending,
            ],
            defaultSidebarVisible: store.isViewingReplyThread
        )
    }

    private var channelHeader: some View {
        HStack(spacing: 10) {
            Text(store.selectedConnectorDisplayName)
                .font(.headline)
            Spacer()
            Menu {
                Picker("Default profile", selection: channelDefaultProfileBinding) {
                    Text("Orchestrator").tag(AgentProfileHandle.orchestrator)
                    ForEach(
                        agentProfiles.enabledProfiles.filter { $0.handle != AgentProfileHandle.orchestrator },
                        id: \.handle
                    ) { profile in
                        Text(profile.displayName).tag(profile.handle)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 12, weight: .medium))
                    Text(channelDefaultProfileLabel)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.white.opacity(0.9), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Default agent profile when someone @s Derrick without $handle")
            Button {
                Task { await store.toggleMuteSelectedThread() }
            } label: {
                Image(systemName: store.selectedThread?.muted == true ? "bell.slash.fill" : "bell")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.9), in: Circle())
            }
            .buttonStyle(.plain)
            .help(store.selectedThread?.muted == true ? "Unmute conversation" : "Mute conversation")
            .accessibilityLabel(store.selectedThread?.muted == true ? "Unmute conversation" : "Mute conversation")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var channelDefaultProfileLabel: String {
        let handle = store.selectedThread?.defaultAgentProfileHandle ?? AgentProfileHandle.orchestrator
        return agentProfiles.profile(handle: handle)?.displayName ?? "Orchestrator"
    }

    private var channelDefaultProfileBinding: Binding<String> {
        Binding(
            get: {
                store.selectedThread?.defaultAgentProfileHandle ?? AgentProfileHandle.orchestrator
            },
            set: { newHandle in
                let normalized = newHandle == AgentProfileHandle.orchestrator ? nil : newHandle
                Task { await store.setChannelDefaultProfile(handle: normalized) }
            }
        )
    }

    private var threadHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Thread")
                    .font(.headline)
                Text(store.selectedThread?.title ?? "Conversation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.closeReplyThread()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.9), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close thread")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
