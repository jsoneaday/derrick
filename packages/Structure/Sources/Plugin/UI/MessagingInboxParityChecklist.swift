import Foundation

/// Behaviors the host messaging inbox must keep covering after HostUI schema render.
public enum MessagingInboxParityChecklist: String, CaseIterable, Sendable {
    case channelTabs = "channel_tabs"
    case messageList = "message_list"
    case bubbleChrome = "bubble_chrome"
    case composer = "composer"
    case replySidebar = "reply_sidebar"
    case replyAffordance = "reply_affordance"
    case optimisticOutbound = "optimistic_outbound"
    case inboundBannerDedupe = "inbound_banner_dedupe"
    case pollDarwinRefresh = "poll_darwin_refresh"
    case threadOpenClose = "thread_open_close"

    public var summary: String {
        switch self {
        case .channelTabs:
            return "Conversation tab strip for open channels/DMs"
        case .messageList:
            return "Scrolling channel message list with older-page load"
        case .bubbleChrome:
            return "Inbound/outbound bubbles with navy/white chrome"
        case .composer:
            return "Channel and reply composers with send"
        case .replySidebar:
            return "Thread side pane when a reply parent is open"
        case .replyAffordance:
            return "Reply in thread / N replies preview under roots"
        case .optimisticOutbound:
            return "Outbound bubble appears on send; poll does not duplicate"
        case .inboundBannerDedupe:
            return "In-app inbound toast with session-lifetime vendor-id dedupe"
        case .pollDarwinRefresh:
            return "Darwin inbound signal reloads threads/messages"
        case .threadOpenClose:
            return "Open/close reply thread and focus composers"
        }
    }
}
