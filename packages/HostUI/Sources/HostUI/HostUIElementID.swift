import Foundation
import Structure

/// Catalog element ids the HostUI renderer understands.
public enum HostUIElementID: String, Sendable, Hashable, CaseIterable {
    case screen
    case sidebar
    case tabStrip = "tab_strip"
    case messageList = "message_list"
    case message
    case composer
    case textField = "text_field"
    case select
    case button
    case text
    case table
    case section
    case calendar
    case time
    // Invisible host services
    case optimisticSend = "optimistic_send"
    case inboundBanners = "inbound_banners"
    case pollRefresh = "poll_refresh"
    case replyPane = "reply_pane"

    public var isService: Bool {
        switch self {
        case .optimisticSend, .inboundBanners, .pollRefresh, .replyPane:
            return true
        default:
            return false
        }
    }
}
