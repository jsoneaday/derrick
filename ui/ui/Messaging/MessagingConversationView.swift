import HostUI
import Structure
import SwiftUI

struct MessagingConversationView: View {
    @ObservedObject var store: MessagingStore
    var onInboundBannerTap: (() -> Void)? = nil
    /// Plugin Chat tab for the connector itself: conversations as inner tabs, replies as a side pane.
    var presentsInbox: Bool = false
    @State private var draft = ""
    @State private var threadDraft = ""
    @State private var channelID = ""
    @State private var selectedVendorThreadID = ""
    @FocusState private var composerFocused: Bool
    @FocusState private var threadComposerFocused: Bool
    @FocusState private var channelFocused: Bool

    var body: some View {
        Color(red: 248.0 / 255.0, green: 248.0 / 255.0, blue: 246.0 / 255.0)
            .ignoresSafeArea()
            .overlay {
                switch store.conversationLanding {
                case .catalogRoot:
                    emptyConnectors
                case .vendorConnector:
                    if presentsInbox {
                        if store.isConnectorSyncing, store.tabs.isEmpty {
                            discoveringThreads
                        } else {
                            conversation
                        }
                    } else if store.selectedThread == nil, store.isConnectorSyncing {
                        discoveringThreads
                    } else if store.selectedThread == nil, store.canPickThread {
                        threadPicker
                    } else if store.selectedThread == nil, store.needsThreadDiscovery {
                        discoveringThreads
                    } else if store.selectedThread == nil, store.canComposeManualChannel {
                        channelCompose
                    } else if store.selectedThread == nil {
                        emptyThreads
                    } else {
                        conversation
                    }
                }
            }
            .onChange(of: store.threads) { _, threads in
                syncPickerSelection(with: threads)
            }
            .onAppear {
                syncPickerSelection(with: store.threads)
                focusPrimaryComposer()
            }
            .onChange(of: store.conversationLanding) { _, _ in
                focusPrimaryComposer()
            }
            .onChange(of: store.selectedThread?.id) { _, _ in
                focusPrimaryComposer()
            }
            .onChange(of: store.selectedPluginID) { _, _ in
                focusPrimaryComposer()
            }
    }

    private func focusPrimaryComposer() {
        DispatchQueue.main.async {
            switch store.conversationLanding {
            case .catalogRoot:
                break
            case .vendorConnector:
                if store.isViewingReplyThread {
                    threadComposerFocused = true
                    return
                }
                if presentsInbox {
                    if store.isConnectorSyncing, store.tabs.isEmpty { return }
                    composerFocused = true
                    return
                }
                if store.selectedThread != nil {
                    composerFocused = true
                    return
                }
                if store.canPickThread { return }
                if store.needsThreadDiscovery || store.isConnectorSyncing { return }
                if store.canComposeManualChannel {
                    if channelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        channelFocused = true
                    } else {
                        composerFocused = true
                    }
                }
            }
        }
    }

    private func syncPickerSelection(with threads: [MessagingThreadDTO]) {
        guard !threads.isEmpty else {
            selectedVendorThreadID = ""
            return
        }
        if selectedVendorThreadID.isEmpty
            || !threads.contains(where: { $0.vendorThreadID == selectedVendorThreadID }) {
            selectedVendorThreadID = threads[0].vendorThreadID
        }
    }

    private var emptyConnectors: some View {
        VStack(spacing: 10) {
            Text("Connector")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
            Text("Installed connectors appear as Chat tabs. Type / then the plugin name, or open one from Settings → Plugins.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
    }

    private var threadPicker: some View {
        HostUIScreen {
            VStack(alignment: .leading, spacing: 14) {
                HostUIText(store.selectedConnectorDisplayName, style: .title, multilineCenter: true)
                    .frame(maxWidth: .infinity, alignment: .center)

                HostUIText(
                    "Choose a conversation. Derrick shows names from the connector; the vendor ID is used behind the scenes.",
                    style: .callout,
                    multilineCenter: true
                )
                .frame(maxWidth: .infinity, alignment: .center)

                HostUISection {
                    HostUISelect(
                        label: "Conversation",
                        options: store.threads.map {
                            HostUISelectOption(id: $0.vendorThreadID, label: $0.title)
                        },
                        selection: $selectedVendorThreadID
                    )
                }

                HStack {
                    if let pluginID = store.selectedPluginID {
                        HostUIButton(
                            "Refresh list",
                            systemImage: "arrow.clockwise",
                            chrome: .secondary,
                            disabled: store.isConnectorSyncing
                        ) {
                            Task { await store.refreshConnector(pluginID: pluginID) }
                        }
                    }
                    Spacer()
                    HostUIButton(
                        "Open conversation",
                        systemImage: "bubble.left.and.bubble.right",
                        disabled: selectedVendorThreadID.isEmpty || store.isConnectorSyncing
                    ) {
                        Task { await store.openDiscoveredThread(vendorThreadID: selectedVendorThreadID) }
                    }
                }

                if let error = store.lastError {
                    HostUIText(error, style: .caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 520)
        }
    }

    private var discoveringThreads: some View {
        VStack(spacing: 10) {
            Text(store.selectedConnectorDisplayName)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
            ProgressView()
                .controlSize(.small)
            Text(store.isConnectorSyncing
                 ? "Loading conversations from the connector…"
                 : "No conversations found yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if !store.isConnectorSyncing, let pluginID = store.selectedPluginID {
                Button {
                    Task { await store.refreshConnector(pluginID: pluginID) }
                } label: {
                    Label("Refresh list", systemImage: "arrow.clockwise")
                }
            }
            if let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
    }

    private var channelCompose: some View {
        HostUIScreen {
            VStack(alignment: .leading, spacing: 14) {
                HostUIText(store.selectedConnectorDisplayName, style: .title, multilineCenter: true)
                    .frame(maxWidth: .infinity, alignment: .center)

                HostUIText(
                    store.canComposeSendOnly
                        ? "Send-only connector — enter a destination ID and message."
                        : "Enter a destination ID to open a conversation. Incoming messages appear after you connect.",
                    style: .callout,
                    multilineCenter: true
                )
                .frame(maxWidth: .infinity, alignment: .center)

                HostUITextField(
                    label: "Destination ID",
                    placeholder: "Destination ID",
                    text: $channelID
                )
                .focused($channelFocused)

                if !store.canComposeSendOnly {
                    HStack {
                        Spacer()
                        HostUIButton(
                            "Connect to channel",
                            systemImage: "antenna.radiowaves.left.and.right",
                            disabled: channelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || store.isConnectorSyncing
                        ) {
                            Task { await store.connectToChannel(channelID) }
                        }
                    }
                }

                HostUIComposer(
                    placeholder: "Message",
                    sendTitle: "Send message",
                    text: $draft,
                    isSending: store.isSending,
                    canSend: canSubmitChannelCompose,
                    onSend: submitChannelCompose
                )
                .focused($composerFocused)

                if let error = store.lastError {
                    HostUIText(error, style: .caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 520)
        }
    }

    private var canSubmitChannelCompose: Bool {
        !store.isSending
            && !channelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitChannelCompose() {
        let channel = channelID
        let text = draft
        draft = ""
        Task {
            await store.sendMessage(toChannel: channel, text: text)
            composerFocused = true
        }
    }

    private var emptyThreads: some View {
        VStack(spacing: 10) {
            Text(store.selectedConnectorDisplayName)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
            if store.isConnectorSyncing {
                ProgressView()
                    .controlSize(.small)
                Text("Syncing channels and recent messages…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("No conversations yet. Open a connector that lists conversations, or refresh the list.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            if let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
    }

    private var conversation: some View {
        ZStack(alignment: .top) {
            MessagingHostUISurface(
                store: store,
                draft: $draft,
                threadDraft: $threadDraft,
                onSubmitChannel: submitChannelDraft,
                onSubmitThread: submitThreadDraft
            )
            if let banner = store.inboundBanner, !banner.isEmpty {
                InAppNotificationToast(text: banner, kind: .message) {
                    onInboundBannerTap?()
                }
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.35), value: store.inboundBanner)
        .onChange(of: store.isViewingReplyThread) { _, open in
            if open {
                threadComposerFocused = true
            } else {
                threadDraft = ""
                composerFocused = true
            }
        }
    }

    private func submitChannelDraft() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        Task {
            await store.sendMessage(text, parentVendorMessageID: nil)
            composerFocused = true
        }
    }

    private func submitThreadDraft() {
        let text = threadDraft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        threadDraft = ""
        let parent = store.selectedReplyParentVendorMessageID
        Task {
            await store.sendMessage(text, parentVendorMessageID: parent)
            threadComposerFocused = true
        }
    }
}

struct MessagingBubble: View {
    let message: MessagingMessageDTO
    var showsReplyAction = false
    var lastReplyPreview: String? = nil
    var onOpenThread: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.direction == .outbound { Spacer(minLength: 80) }
            VStack(alignment: message.direction == .outbound ? .trailing : .leading, spacing: 4) {
                    Text(message.sender)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                messageBody
                if showsReplyAction {
                    Button(action: onOpenThread) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.caption.weight(.semibold))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(replyActionTitle)
                                    .font(.caption.weight(.semibold))
                                if message.replyCount > 0, let preview = lastReplyPreview, !preview.isEmpty {
                                    AgentProfileHighlightedText(
                                        text: preview,
                                        font: .caption2,
                                        baseColor: .secondary
                                    )
                                    .lineLimit(1)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white)
                                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .foregroundStyle(message.replyCount > 0 ? Color.accentColor : .primary.opacity(0.75))
                    .help(message.replyCount > 0 ? "Open thread" : "Reply in thread")
                    .accessibilityLabel(replyActionTitle)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: message.direction == .outbound ? .trailing : .leading)
            if message.direction == .inbound { Spacer(minLength: 80) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var messageBody: some View {
        bubbleLabel
            .frame(maxWidth: 420, alignment: message.direction == .outbound ? .trailing : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .modifier(MessagingBubbleChrome(direction: message.direction))
            .frame(
                maxWidth: .infinity,
                alignment: message.direction == .outbound ? .trailing : .leading
            )
    }

    private var bubbleLabel: some View {
        MessagingMarkdownText(
            text: message.body,
            fontSize: 13
        )
    }

    private var replyActionTitle: String {
        if message.replyCount == 1 {
            return "1 reply"
        }
        if message.replyCount > 1 {
            return "\(message.replyCount) replies"
        }
        return "Reply in thread"
    }
}

private struct MessagingBubbleChrome: ViewModifier {
    let direction: MessagingMessageDirection

    private var kind: InAppNotificationKind {
        direction == .outbound ? .message : .info
    }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        direction == .outbound
                            ? InAppNotificationBannerChrome.fill
                            : Color.white
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(kind.accent.opacity(direction == .outbound ? 0.28 : 0.14), lineWidth: 1)
            )
    }
}
