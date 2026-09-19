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

    public init(
        id: String,
        sender: String,
        body: String,
        outbound: Bool,
        replyCount: Int = 0,
        replyPreview: String? = nil,
        showsReplyAction: Bool = false
    ) {
        self.id = id
        self.sender = sender
        self.body = body
        self.outbound = outbound
        self.replyCount = replyCount
        self.replyPreview = replyPreview
        self.showsReplyAction = showsReplyAction
    }
}

public struct HostUIMessage: View {
    private let row: HostUIMessageRow
    private let onOpenThread: (() -> Void)?

    private let navy = Color(red: 0.176, green: 0.286, blue: 0.576)

    public init(row: HostUIMessageRow, onOpenThread: (() -> Void)? = nil) {
        self.row = row
        self.onOpenThread = onOpenThread
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if row.outbound { Spacer(minLength: 80) }
            VStack(alignment: row.outbound ? .trailing : .leading, spacing: 4) {
                if !row.sender.isEmpty {
                    Text(row.sender)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HostUIMarkdownText(row.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                navy.opacity(row.outbound ? 0.32 : 0.14),
                                lineWidth: 1
                            )
                    )
                if row.showsReplyAction, let onOpenThread {
                    Button(action: onOpenThread) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.caption.weight(.semibold))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(replyTitle)
                                    .font(.caption.weight(.semibold))
                                if row.replyCount > 0, let preview = row.replyPreview, !preview.isEmpty {
                                    HostUIMarkdownText(preview, font: .caption2)
                                        .foregroundStyle(.secondary)
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
                    .foregroundStyle(row.replyCount > 0 ? Color.accentColor : .primary.opacity(0.75))
                }
            }
            .frame(maxWidth: .infinity, alignment: row.outbound ? .trailing : .leading)
            if !row.outbound { Spacer(minLength: 80) }
        }
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

    public init(
        rows: [HostUIMessageRow],
        onOpenThread: ((HostUIMessageRow) -> Void)? = nil,
        onNearBottomChange: ((Bool) -> Void)? = nil,
        onLoadOlder: (() -> Void)? = nil
    ) {
        self.rows = rows
        self.onOpenThread = onOpenThread
        self.onNearBottomChange = onNearBottomChange
        self.onLoadOlder = onLoadOlder
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
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: rows.last?.id) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("hostui-scroll-bottom", anchor: .bottom)
                }
            }
        }
    }
}

public struct HostUIComposer: View {
    @Binding private var text: String
    private let placeholder: String
    private let isSending: Bool
    private let canSend: Bool
    private let onSubmit: () -> Void

    public init(
        text: Binding<String>,
        placeholder: String = "Message",
        isSending: Bool = false,
        canSend: Bool = true,
        onSubmit: @escaping () -> Void
    ) {
        self._text = text
        self.placeholder = placeholder
        self.isSending = isSending
        self.canSend = canSend
        self.onSubmit = onSubmit
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .onSubmit(onSubmit)

            Button(action: onSubmit) {
                Image(systemName: isSending ? "hourglass" : "paperplane.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.borderless)
            .disabled(!canSend || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }
}
