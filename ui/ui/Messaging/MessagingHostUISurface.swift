import HostUI
import Structure
import SwiftUI

/// Renders `store.hostUIRoot` through the HostUI tree pipeline (controls + services).
struct MessagingHostUISurface: View {
    @ObservedObject var store: MessagingStore
    @Binding var draft: String
    @Binding var threadDraft: String
    var onInboundBannerTap: (() -> Void)? = nil
    @ObservedObject private var agentProfiles = AgentProfileStore.shared

    var body: some View {
        VStack(spacing: 0) {
            channelHeader
            HostUINodeView(node: store.hostUIRoot, bindings: makeBindings())
        }
        .background(Color(red: 248.0 / 255.0, green: 248.0 / 255.0, blue: 246.0 / 255.0))
    }

    private func makeBindings() -> HostUINodeBindings {
        let root = store.hostUIRoot
        let services = HostUILibraryStore.serviceIDs(in: root)
        return HostUINodeBindings(
            tabs: store.tabs.map {
                HostUITabItem(
                    id: $0.id,
                    title: $0.title,
                    unreadCount: $0.unreadCount,
                    muted: $0.muted
                )
            },
            selectedTabID: store.selectedThreadID,
            channelMessages: store.visibleMessages
                .filter { !$0.isReply }
                .map { messageRow(from: $0, showsReply: true) },
            threadMessages: store.visibleReplyMessages.map { messageRow(from: $0, showsReply: false) },
            channelDraft: $draft,
            threadDraft: $threadDraft,
            isSending: store.isSending,
            canSendChannel: store.canSendInSelectedThread,
            canSendThread: store.canSendInSelectedThread,
            isViewingReplyThread: store.isViewingReplyThread,
            replyThreadTitle: store.replyThreadTitle,
            replyThreadWarning: store.replyThreadWarning,
            inboundBanner: store.inboundBanner,
            onSelectTab: { id in
                Task { await store.selectThread(id: id) }
            },
            onSubmitChannel: {
                let text = draft
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                draft = ""
                let optimisticID = store.beginOptimisticSend(
                    text: text,
                    parentVendorMessageID: nil
                )
                Task {
                    await store.sendMessage(
                        text,
                        parentVendorMessageID: nil,
                        optimisticID: optimisticID
                    )
                }
            },
            onSubmitThread: {
                let text = threadDraft
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                threadDraft = ""
                let parent = store.selectedReplyParentVendorMessageID
                let optimisticID = store.beginOptimisticSend(
                    text: text,
                    parentVendorMessageID: parent
                )
                Task {
                    await store.sendMessage(
                        text,
                        parentVendorMessageID: parent,
                        optimisticID: optimisticID
                    )
                }
            },
            onOpenThread: { row in
                guard let message = store.visibleMessages.first(where: { $0.id == row.id }),
                      let parent = message.vendorMessageID
                else { return }
                Task { await store.openReplyThread(parentVendorMessageID: parent) }
            },
            onCloseReplyThread: {
                store.closeReplyThread()
            },
            onBannerTap: {
                onInboundBannerTap?()
            },
            onNearBottomChange: { near in
                store.setNearBottom(near)
            },
            onLoadOlder: {
                Task { await store.loadOlderIfNeeded() }
            },
            showJumpToLatest: store.showJumpToLatest,
            showNewMessagesPill: store.showNewMessagesPill,
            onJumpToLatest: {
                Task { await store.jumpToLatest() }
            },
            scrollToBottomToken: store.scrollToBottomToken,
            threadAgentWorkStatus: store.agentWorkStatus(
                forParent: store.selectedReplyParentVendorMessageID
            ),
            activeServices: services
        )
    }

    private func messageRow(from message: MessagingMessageDTO, showsReply: Bool) -> HostUIMessageRow {
        HostUIMessageRow(
            id: message.id,
            sender: message.sender,
            body: message.body,
            outbound: message.direction == .outbound,
            replyCount: message.replyCount,
            replyPreview: message.vendorMessageID.flatMap { id in
                store.lastReplyPreviewByParentID[id].map(HostUIMessagingLayout.collapsedReplyPreview)
            },
            showsReplyAction: showsReply && message.vendorMessageID != nil,
            agentWorkStatus: store.agentWorkStatus(forParent: message.vendorMessageID)
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
}
