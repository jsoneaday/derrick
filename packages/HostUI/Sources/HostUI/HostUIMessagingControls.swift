import SwiftUI

public struct HostUITabItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var unreadCount: Int
    public var muted: Bool

    public init(id: String, title: String, unreadCount: Int = 0, muted: Bool = false) {
        self.id = id
        self.title = title
        self.unreadCount = unreadCount
        self.muted = muted
    }
}

/// Dark selected pill / light unselected pill — host messaging conversation strip.
public struct HostUITabStrip: View {
    private let tabs: [HostUITabItem]
    private let selectedID: String?
    private let onSelect: (String) -> Void

    private let chromeFill = Color(red: 248.0 / 255.0, green: 248.0 / 255.0, blue: 246.0 / 255.0)
    private let selectedFill = Color(red: 0.18, green: 0.18, blue: 0.17)
    private let unselectedFill = Color.primary.opacity(0.06)

    public init(
        tabs: [HostUITabItem],
        selectedID: String?,
        onSelect: @escaping (String) -> Void
    ) {
        self.tabs = tabs
        self.selectedID = selectedID
        self.onSelect = onSelect
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tabs) { tab in
                    pill(tab)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(chromeFill)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }

    private func pill(_ tab: HostUITabItem) -> some View {
        let selected = tab.id == selectedID
        return Button {
            onSelect(tab.id)
        } label: {
            HStack(spacing: 6) {
                if tab.muted {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(tab.title)
                    .lineLimit(1)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                if tab.unreadCount > 0 {
                    Text(tab.unreadCount > 99 ? "99+" : "\(tab.unreadCount)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(selected ? selectedFill : .white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(selected ? chromeFill.opacity(0.9) : Color.accentColor, in: Capsule())
                }
            }
            .foregroundStyle(selected ? chromeFill : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(selected ? selectedFill : unselectedFill, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(tab.title)
    }
}

public struct HostUIMessageRow: Identifiable, Hashable, Sendable {
    public var id: String
    public var sender: String
    public var body: String
    public var outbound: Bool
    public var replyCount: Int
    public var replyPreview: String?
    public var showsReplyAction: Bool
    /// Shown only while an agent turn for this parent has started.
    public var agentWorkStatus: String?

    public init(
        id: String,
        sender: String,
        body: String,
        outbound: Bool,
        replyCount: Int = 0,
        replyPreview: String? = nil,
        showsReplyAction: Bool = false,
        agentWorkStatus: String? = nil
    ) {
        self.id = id
        self.sender = sender
        self.body = body
        self.outbound = outbound
        self.replyCount = replyCount
        self.replyPreview = replyPreview
        self.showsReplyAction = showsReplyAction
        self.agentWorkStatus = agentWorkStatus
    }
}

public struct HostUIMessage: View {
    private let row: HostUIMessageRow
    private let onOpenThread: (() -> Void)?

    public init(row: HostUIMessageRow, onOpenThread: (() -> Void)? = nil) {
        self.row = row
        self.onOpenThread = onOpenThread
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if row.outbound { Spacer(minLength: HostUIMessagingLayout.oppositeGutter) }
            VStack(alignment: row.outbound ? .trailing : .leading, spacing: 4) {
                if !row.sender.isEmpty {
                    Text(row.sender)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HostUIMessageBubble(bodyMarkdown: row.body)
                if let work = row.agentWorkStatus, !work.isEmpty {
                    HostUIAgentWorkIndicator(status: work)
                }
                if row.showsReplyAction, let onOpenThread {
                    replyAffordance(onOpenThread)
                }
            }
            .frame(maxWidth: .infinity, alignment: row.outbound ? .trailing : .leading)
            if !row.outbound { Spacer(minLength: HostUIMessagingLayout.oppositeGutter) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func replyAffordance(_ onOpenThread: @escaping () -> Void) -> some View {
        Button(action: onOpenThread) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.caption.weight(.semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(replyTitle)
                        .font(.caption.weight(.semibold))
                    if row.replyCount > 0, let preview = row.replyPreview, !preview.isEmpty {
                        // Plain one-line preview only — never expand the full thread body here.
                        Text(HostUIMessagingLayout.collapsedReplyPreview(preview))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
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
        .foregroundStyle(row.replyCount > 0 ? HostUIMessagingLayout.navy : .primary.opacity(0.75))
        .fixedSize(horizontal: true, vertical: false)
    }

    private var replyTitle: String {
        if row.replyCount == 1 { return "1 reply" }
        if row.replyCount > 1 { return "\(row.replyCount) replies" }
        return "Reply in thread"
    }
}

public struct HostUIMessageList: View {
    private let rows: [HostUIMessageRow]
    private let onOpenThread: ((HostUIMessageRow) -> Void)?
    private let onNearBottomChange: ((Bool) -> Void)?
    private let onLoadOlder: (() -> Void)?
    private let scrollToBottomToken: Int

    public init(
        rows: [HostUIMessageRow],
        onOpenThread: ((HostUIMessageRow) -> Void)? = nil,
        onNearBottomChange: ((Bool) -> Void)? = nil,
        onLoadOlder: (() -> Void)? = nil,
        scrollToBottomToken: Int = 0
    ) {
        self.rows = rows
        self.onOpenThread = onOpenThread
        self.onNearBottomChange = onNearBottomChange
        self.onLoadOlder = onLoadOlder
        self.scrollToBottomToken = scrollToBottomToken
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if onLoadOlder != nil {
                        Color.clear
                            .frame(height: 1)
                            .onAppear { onLoadOlder?() }
                    }
                    ForEach(rows) { row in
                        HostUIMessage(row: row) {
                            onOpenThread?(row)
                        }
                        .id(row.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("hostui-scroll-bottom")
                        .onAppear { onNearBottomChange?(true) }
                        .onDisappear { onNearBottomChange?(false) }
                }
                .padding(.horizontal, HostUIMessagingLayout.listPaddingX)
                .padding(.vertical, 12)
            }
            .frame(minHeight: 0)
            .onChange(of: rows.last?.id) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: scrollToBottomToken) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo("hostui-scroll-bottom", anchor: .bottom)
        }
    }
}

public struct HostUIComposer: View {
    @Binding private var text: String
    private let placeholder: String
    private let sendTitle: String
    private let isSending: Bool
    private let canSend: Bool
    private let onSubmit: () -> Void

    public init(
        text: Binding<String>,
        placeholder: String = "Message",
        sendTitle: String = "Send",
        isSending: Bool = false,
        canSend: Bool = true,
        onSubmit: @escaping () -> Void
    ) {
        self._text = text
        self.placeholder = placeholder
        self.sendTitle = sendTitle
        self.isSending = isSending
        self.canSend = canSend
        self.onSubmit = onSubmit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .allowsHitTesting(false)
                }
                TextField("", text: $text, axis: .vertical)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(.clear)
                    .onSubmit(submitIfAllowed)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 12)
            .frame(minHeight: 76, alignment: .topLeading)

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)

            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Button(action: submitIfAllowed) {
                    HStack(spacing: 6) {
                        Image(systemName: isSending ? "hourglass" : "paperplane.fill")
                        Text(isSending ? "Sending…" : sendTitle)
                    }
                }
                .buttonStyle(HostUIPrimaryButtonStyle())
                .disabled(!canSubmit)
                .opacity(canSubmit ? 1 : 0.45)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color(red: 248.0 / 255.0, green: 248.0 / 255.0, blue: 246.0 / 255.0))
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var canSubmit: Bool {
        canSend
            && !isSending
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitIfAllowed() {
        guard canSubmit else { return }
        onSubmit()
    }
}

#Preview("Messaging composer") {
    HostUIComposerPreviewHost(initial: "")
        .frame(width: 720)
        .padding()
        .background(Color(red: 245 / 255, green: 244 / 255, blue: 240 / 255))
}

#Preview("Messaging composer filled") {
    HostUIComposerPreviewHost(initial: "hello from channel")
        .frame(width: 720)
        .padding()
        .background(Color(red: 245 / 255, green: 244 / 255, blue: 240 / 255))
}

#Preview("Channel reply preview") {
    HostUIMessage(
        row: HostUIMessageRow(
            id: "root",
            sender: "derrick",
            body: "hello",
            outbound: true,
            replyCount: 1,
            replyPreview: """
            This is a long thread reply that must stay one line in the channel.
            Second paragraph must not appear as a channel message.
            """,
            showsReplyAction: true
        ),
        onOpenThread: {}
    )
    .padding()
    .frame(width: 720)
    .background(Color(red: 245 / 255, green: 244 / 255, blue: 240 / 255))
}

#Preview("Inbound vs outbound bubbles") {
    VStack(alignment: .leading, spacing: 16) {
        HostUIMessage(
            row: HostUIMessageRow(
                id: "in",
                sender: "David Choi (jsoneaday)",
                body: "$orchestrator today's news",
                outbound: false,
                showsReplyAction: true
            ),
            onOpenThread: {}
        )
        HostUIMessage(
            row: HostUIMessageRow(
                id: "out-long",
                sender: "derrick",
                body: "hi from derrick",
                outbound: true,
                showsReplyAction: true
            ),
            onOpenThread: {}
        )
        HostUIMessage(
            row: HostUIMessageRow(
                id: "out-short",
                sender: "derrick",
                body: "hi",
                outbound: true,
                showsReplyAction: true
            ),
            onOpenThread: {}
        )
    }
    .padding()
    .frame(width: 720)
    .background(Color(red: 245 / 255, green: 244 / 255, blue: 240 / 255))
}

#Preview("Weather bubble in thread pane") {
    HostUIMessage(
        row: HostUIMessageRow(
            id: "wx",
            sender: "derrick",
            body: """
            [Derrick:orchestrator] Searching the web…

            In **Northvale, NJ 07647**, Weather Underground reported **62°F** at **7:27 AM EDT on September 19, 2026**. Its listed daily temp **71°F / 63°F**.

            [View current conditions on Weather Underground](https://www.wunderground.com)
            """,
            outbound: true
        )
    )
    .padding(12)
    .frame(width: 360, height: 420)
    .background(Color(red: 245 / 255, green: 244 / 255, blue: 240 / 255))
}

private struct HostUIComposerPreviewHost: View {
    @State private var text: String

    init(initial: String = "") {
        _text = State(initialValue: initial)
    }

    var body: some View {
        HostUIComposer(text: $text, placeholder: "Message #general", onSubmit: {})
    }
}
