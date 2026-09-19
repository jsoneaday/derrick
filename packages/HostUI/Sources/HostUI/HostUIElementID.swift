import Foundation

/// Element ids from `host-ui-library.json`. App and plugin trees share these ids.
public enum HostUIElementID: String, Sendable, Hashable, CaseIterable {
    case screen
    case sidebar
    case section
    case tabStrip = "tab_strip"
    case messageList = "message_list"
    case message
    case composer
    case textField = "text_field"
    case select
    case button
    case text
    case table
    case calendar
    case time
}
