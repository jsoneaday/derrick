import Structure
import SwiftUI

struct MessagingConversationView: View {
    @ObservedObject var store: MessagingStore
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
                    if store.selectedThread == nil, store.isConnectorSyncing {
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
            Text("Messaging")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
            Text("Connector plugins show up here. Create a messaging connector plugin to start.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
    }

    private var threadPicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(store.selectedConnectorDisplayName)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .center)

            Text("Choose a conversation. Derrick shows names from the connector; the vendor ID is used behind the scenes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            VStack(alignment: .leading, spacing: 6) {
                Text("Conversation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Conversation", selection: $selectedVendorThreadID) {
                    ForEach(store.threads, id: \.vendorThreadID) { thread in
                        Text(thread.title).tag(thread.vendorThreadID)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            HStack {
                if let pluginID = store.selectedPluginID {
                    Button {
                        Task { await store.refreshConnector(pluginID: pluginID) }
                    } label: {
                        Label("Refresh list", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isConnectorSyncing)
                }
                Spacer()
                Button {
                    Task { await store.openDiscoveredThread(vendorThreadID: selectedVendorThreadID) }
                } label: {
                    Label("Open conversation", systemImage: "bubble.left.and.bubble.right")
                }
                .buttonStyle(ModalPrimaryButtonStyle())
                .disabled(selectedVendorThreadID.isEmpty || store.isConnectorSyncing)
            }

            if let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 520)
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
        VStack(alignment: .leading, spacing: 14) {
            Text(store.selectedConnectorDisplayName)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .center)

            Text(store.canComposeSendOnly
                 ? "Send-only connector — enter a destination ID and message."
                 : "Enter a destination ID to open a conversation. Incoming messages appear after you connect.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            VStack(alignment: .leading, spacing: 6) {
                Text("Destination ID")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Destination ID", text: $channelID)
                    .textFieldStyle(.roundedBorder)
                    .focused($channelFocused)
            }

            if !store.canComposeSendOnly {
                HStack {
                    Spacer()
                    Button {
                        Task { await store.connectToChannel(channelID) }
                    } label: {
                        Label("Connect to channel", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .buttonStyle(ModalPrimaryButtonStyle())
                    .disabled(channelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isConnectorSyncing)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Message")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
            }

            HStack {
                Spacer()
                Button {
                    submitChannelCompose()
                } label: {
                    Label(store.isSending ? "Sending…" : "Send message", systemImage: "paperplane.fill")
                }
                .buttonStyle(ModalPrimaryButtonStyle())
                .disabled(!canSubmitChannelCompose)
            }

            if let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 520)
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
            HStack(spacing: 0) {
                channelPane
                if store.isViewingReplyThread {
                    Divider()
                    threadPane
                        .frame(minWidth: 300, idealWidth: 360, maxWidth: 440)
                }
            }
            if let banner = store.inboundBanner, !banner.isEmpty {
                Text(banner)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: 520)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
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

    private var channelPane: some View {
        VStack(spacing: 0) {
            channelHeader
            ZStack(alignment: .bottom) {
                messageList(
                    messages: store.visibleMessages,
                    showsReplyAction: true,
                    loadsOlder: true,
                    bottomID: "channel-scroll-bottom"
                )
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
            composer(
                text: $draft,
                placeholder: "Message",
                focused: $composerFocused,
                submit: submitChannelDraft
            )
        }
    }

    private var threadPane: some View {
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
            messageList(
                messages: store.visibleReplyMessages,
                showsReplyAction: false,
                loadsOlder: false,
                bottomID: "thread-scroll-bottom"
            )
            composer(
                text: $threadDraft,
                placeholder: "Reply",
                focused: $threadComposerFocused,
                submit: submitThreadDraft
            )
        }
        .background(Color.white.opacity(0.55))
    }

    private var channelHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.selectedThread?.title ?? "Conversation")
                    .font(.headline)
                Text(store.selectedConnectorDisplayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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

    private func messageList(
        messages: [MessagingMessageDTO],
        showsReplyAction: Bool,
        loadsOlder: Bool,
        bottomID: String
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Color.clear
                        .frame(height: 1)
                        .onAppear {
                            if loadsOlder {
                                Task { await store.loadOlderIfNeeded() }
                            }
                        }
                    ForEach(messages) { message in
                        MessagingBubble(
                            message: message,
                            showsReplyAction: showsReplyAction && message.vendorMessageID != nil,
                            lastReplyPreview: message.vendorMessageID.flatMap {
                                store.lastReplyPreviewByParentID[$0]
                            }
                        ) {
                            if let parent = message.vendorMessageID {
                                Task { await store.openReplyThread(parentVendorMessageID: parent) }
                            }
                        }
                        .id(message.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                        .onAppear {
                            if loadsOlder {
                                store.setNearBottom(true)
                            }
                        }
                        .onDisappear {
                            if loadsOlder {
                                store.setNearBottom(false)
                            }
                        }
                }
                .padding(.horizontal, showsReplyAction ? 24 : 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .onAppear {
                scrollToBottom(proxy, id: bottomID, animated: false)
            }
            .onChange(of: store.scrollToBottomToken) { _, _ in
                scrollToBottom(proxy, id: bottomID)
            }
            .onChange(of: store.scrollAnchorID) { _, id in
                guard loadsOlder, let id else { return }
                proxy.scrollTo(id, anchor: .top)
            }
        }
    }

    private func composer(
        text: Binding<String>,
        placeholder: String,
        focused: FocusState<Bool>.Binding,
        submit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.isConnectorSyncing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Syncing connector…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    placeholder,
                    text: text,
                    axis: .vertical
                )
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused(focused)
                    .disabled(!store.canSendInSelectedThread)
                    .onSubmit(submit)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )

                Button(action: submit) {
                    Image(systemName: store.isSending ? "hourglass" : "paperplane.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderless)
                .disabled(
                    !store.canSendInSelectedThread
                        || text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            if let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, placeholder == "Reply" ? 16 : 24)
        .padding(.bottom, 16)
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

    private func scrollToBottom(_ proxy: ScrollViewProxy, id: String, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }
}

private struct MessagingBubble: View {
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
        ViewThatFits(in: .horizontal) {
            bubbleLabel
                .fixedSize()
                .modifier(MessagingBubbleChrome(direction: message.direction))
            bubbleLabel
                .fixedSize(horizontal: false, vertical: true)
                .modifier(MessagingBubbleChrome(direction: message.direction))
        }
        .frame(
            maxWidth: .infinity,
            alignment: message.direction == .outbound ? .trailing : .leading
        )
    }

    private var bubbleLabel: some View {
        AgentProfileHighlightedText(
            text: message.body,
            font: .system(size: 13)
        )
        .multilineTextAlignment(.leading)
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

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(direction == .outbound
                          ? Color.black.opacity(0.08)
                          : Color.white)
            )
    }
}
