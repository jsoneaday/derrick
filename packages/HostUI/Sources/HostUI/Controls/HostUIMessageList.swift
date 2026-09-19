import SwiftUI

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
        outbound: Bool = false,
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

public struct HostUIMessageList<Row: View>: View {
    private let rows: [HostUIMessageRow]
    private let bottomID: String
    private let loadsOlder: Bool
    private let onLoadOlder: () -> Void
    private let onNearBottomChange: (Bool) -> Void
    private let scrollToBottomToken: Int
    private let scrollAnchorID: String?
    private let rowContent: (HostUIMessageRow) -> Row

    public init(
        rows: [HostUIMessageRow],
        bottomID: String,
        loadsOlder: Bool = false,
        scrollToBottomToken: Int = 0,
        scrollAnchorID: String? = nil,
        onLoadOlder: @escaping () -> Void = {},
        onNearBottomChange: @escaping (Bool) -> Void = { _ in },
        @ViewBuilder rowContent: @escaping (HostUIMessageRow) -> Row
    ) {
        self.rows = rows
        self.bottomID = bottomID
        self.loadsOlder = loadsOlder
        self.scrollToBottomToken = scrollToBottomToken
        self.scrollAnchorID = scrollAnchorID
        self.onLoadOlder = onLoadOlder
        self.onNearBottomChange = onNearBottomChange
        self.rowContent = rowContent
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Color.clear
                        .frame(height: 1)
                        .onAppear {
                            if loadsOlder { onLoadOlder() }
                        }
                    ForEach(rows) { row in
                        rowContent(row)
                            .id(row.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                        .onAppear {
                            if loadsOlder { onNearBottomChange(true) }
                        }
                        .onDisappear {
                            if loadsOlder { onNearBottomChange(false) }
                        }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .onAppear {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            .onChange(of: scrollToBottomToken) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
            .onChange(of: scrollAnchorID) { _, id in
                guard loadsOlder, let id else { return }
                proxy.scrollTo(id, anchor: .top)
            }
        }
    }
}

extension HostUIMessageList where Row == HostUIMessage {
    public init(
        rows: [HostUIMessageRow],
        bottomID: String,
        loadsOlder: Bool = false,
        scrollToBottomToken: Int = 0,
        scrollAnchorID: String? = nil,
        onLoadOlder: @escaping () -> Void = {},
        onNearBottomChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.init(
            rows: rows,
            bottomID: bottomID,
            loadsOlder: loadsOlder,
            scrollToBottomToken: scrollToBottomToken,
            scrollAnchorID: scrollAnchorID,
            onLoadOlder: onLoadOlder,
            onNearBottomChange: onNearBottomChange
        ) { row in
            HostUIMessage(sender: row.sender, body: row.body, outbound: row.outbound)
        }
    }
}
