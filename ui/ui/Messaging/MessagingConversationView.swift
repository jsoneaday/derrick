import HostUI
import Structure
import SwiftUI

/// Landing / picker chrome for messaging; active conversations render via HostUI.
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
                        if store.hostUIRoot == nil {
                            MessagingAwaitingHostUI(
                                connectorName: store.selectedConnectorDisplayName,
                                isSyncing: store.isConnectorSyncing,
                                lastError: store.lastError,
                                onRefresh: {
                                    guard let pluginID = store.selectedPluginID else { return }
                                    Task { await store.refreshConnector(pluginID: pluginID) }
                                }
                            )
                        } else {
                            hostUIConversation
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
                        hostUIConversation
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

    private var hostUIConversation: some View {
        MessagingHostUISurface(
            store: store,
            draft: $draft,
            threadDraft: $threadDraft,
            onInboundBannerTap: onInboundBannerTap
        )
    }

    private func focusPrimaryComposer() {
        DispatchQueue.main.async {
            switch store.conversationLanding {
            case .catalogRoot:
                break
            case .vendorConnector:
                if presentsInbox {
                    // HostUI composer owns focus for the inbox path.
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
            Text("Installed connectors appear as Chat tabs. Type / then the plugin name, or open one from Plugins → List.")
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
                HostUITextField("Destination ID", text: $channelID)
                    .focused($channelFocused)
            }

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

            VStack(alignment: .leading, spacing: 6) {
                Text("Message")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HostUITextField("Message", text: $draft, axis: .vertical)
                    .focused($composerFocused)
            }

            HStack {
                Spacer()
                HostUIButton(
                    store.isSending ? "Sending…" : "Send message",
                    systemImage: "paperplane.fill",
                    disabled: !canSubmitChannelCompose,
                    action: submitChannelCompose
                )
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
            Text("No conversations yet. Open a connector that lists conversations, or refresh the list.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
    }
}

/// Shown until this connector records a `ui.present` tree.
private struct MessagingAwaitingHostUI: View {
    var connectorName: String
    var isSyncing: Bool
    var lastError: String?
    var onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(connectorName)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
            if isSyncing {
                ProgressView()
                    .controlSize(.small)
            }
            Text(isSyncing
                 ? "Opening this connector…"
                 : "This connector hasn't shown a screen yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if !isSyncing {
                Button(action: onRefresh) {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
            }
            if let lastError, !lastError.isEmpty {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
    }
}