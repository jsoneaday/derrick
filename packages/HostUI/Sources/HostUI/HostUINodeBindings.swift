import Foundation
import Structure
import SwiftUI

/// Interactive data the host supplies when rendering a `HostUINode` tree.
public struct HostUINodeBindings {
    public var tabs: [HostUITabItem]
    public var selectedTabID: String?
    public var channelMessages: [HostUIMessageRow]
    public var threadMessages: [HostUIMessageRow]
    public var channelDraft: Binding<String>
    public var threadDraft: Binding<String>
    public var isSending: Bool
    public var canSendChannel: Bool
    public var canSendThread: Bool
    public var isViewingReplyThread: Bool
    public var replyThreadTitle: String
    public var replyThreadWarning: String?
    public var inboundBanner: String?
    public var onSelectTab: (String) -> Void
    public var onSubmitChannel: () -> Void
    public var onSubmitThread: () -> Void
    public var onOpenThread: (HostUIMessageRow) -> Void
    public var onCloseReplyThread: () -> Void
    public var onBannerTap: () -> Void
    public var onNearBottomChange: (Bool) -> Void
    public var onLoadOlder: () -> Void
    public var showJumpToLatest: Bool
    public var showNewMessagesPill: Bool
    public var onJumpToLatest: () -> Void
    public var scrollToBottomToken: Int
    /// Declared / default service ids active for this tree.
    public var activeServices: Set<String>

    public init(
        tabs: [HostUITabItem] = [],
        selectedTabID: String? = nil,
        channelMessages: [HostUIMessageRow] = [],
        threadMessages: [HostUIMessageRow] = [],
        channelDraft: Binding<String> = .constant(""),
        threadDraft: Binding<String> = .constant(""),
        isSending: Bool = false,
        canSendChannel: Bool = true,
        canSendThread: Bool = true,
        isViewingReplyThread: Bool = false,
        replyThreadTitle: String = "Thread",
        replyThreadWarning: String? = nil,
        inboundBanner: String? = nil,
        onSelectTab: @escaping (String) -> Void = { _ in },
        onSubmitChannel: @escaping () -> Void = {},
        onSubmitThread: @escaping () -> Void = {},
        onOpenThread: @escaping (HostUIMessageRow) -> Void = { _ in },
        onCloseReplyThread: @escaping () -> Void = {},
        onBannerTap: @escaping () -> Void = {},
        onNearBottomChange: @escaping (Bool) -> Void = { _ in },
        onLoadOlder: @escaping () -> Void = {},
        showJumpToLatest: Bool = false,
        showNewMessagesPill: Bool = false,
        onJumpToLatest: @escaping () -> Void = {},
        scrollToBottomToken: Int = 0,
        activeServices: Set<String> = []
    ) {
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.channelMessages = channelMessages
        self.threadMessages = threadMessages
        self.channelDraft = channelDraft
        self.threadDraft = threadDraft
        self.isSending = isSending
        self.canSendChannel = canSendChannel
        self.canSendThread = canSendThread
        self.isViewingReplyThread = isViewingReplyThread
        self.replyThreadTitle = replyThreadTitle
        self.replyThreadWarning = replyThreadWarning
        self.inboundBanner = inboundBanner
        self.onSelectTab = onSelectTab
        self.onSubmitChannel = onSubmitChannel
        self.onSubmitThread = onSubmitThread
        self.onOpenThread = onOpenThread
        self.onCloseReplyThread = onCloseReplyThread
        self.onBannerTap = onBannerTap
        self.onNearBottomChange = onNearBottomChange
        self.onLoadOlder = onLoadOlder
        self.showJumpToLatest = showJumpToLatest
        self.showNewMessagesPill = showNewMessagesPill
        self.onJumpToLatest = onJumpToLatest
        self.scrollToBottomToken = scrollToBottomToken
        self.activeServices = activeServices
    }

    public static func empty() -> HostUINodeBindings {
        HostUINodeBindings()
    }

    public func hasService(_ id: HostUIElementID) -> Bool {
        activeServices.contains(id.rawValue)
    }
}
