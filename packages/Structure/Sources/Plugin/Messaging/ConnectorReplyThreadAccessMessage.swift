import Foundation

/// User-facing copy when a nested reply thread cannot be loaded.
/// The guest maps vendor errors into title/summary; the host only translates a few common codes.
public enum ConnectorReplyThreadAccessMessage: Sendable {
    public static let readMessagesSetupHint = """
    This connector needs permission to read messages, including replies in threads. After you add that permission, reconnect with a new token.
    """

    public static let repliesDidNotLoad = """
    This message has replies, but they didn’t load. The connector may not have permission to read messages. Add that permission, then update the token.
    """

    public static let readPermissionBlocked = """
    This connector could not read that thread. Allow it to read messages, then save a new token.
    """

    public static let botNotInChannel = """
    This connector isn’t in that conversation. Invite it, then try again.
    """

    public static func userFacing(fromVendorDetail detail: String) -> String? {
        let lowered = detail.lowercased()
        if lowered.contains("missing_scope") || lowered.contains("no_permission") {
            return readPermissionBlocked
        }
        if lowered.contains("not_in_channel") {
            return botNotInChannel
        }
        if lowered.contains("thread_not_found") {
            return "That thread could not be found. It may have been deleted."
        }
        return nil
    }
}
