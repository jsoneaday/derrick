import Foundation

/// User-facing copy when a nested reply thread cannot be loaded.
/// Slack does not have a separate “enable threads” switch; the same read-message
/// permission that covers channel history also covers `conversations.replies`.
public enum ConnectorReplyThreadAccessMessage: Sendable {
    public static let slackSetupHint = """
    Your Slack app must be allowed to read messages, including replies in threads. After you add that permission, reinstall the app and paste the new bot token here.
    """

    public static let repliesDidNotLoad = """
    This message has replies in Slack, but they didn’t load. Slack may not have given this app permission to read messages. In your Slack app, allow it to read messages, reinstall the app, then update the token here.
    """

    public static let slackBlockedThread = """
    Slack blocked reading this thread. In your Slack app, allow it to read messages, reinstall the app, then save the new bot token here.
    """

    public static let botNotInChannel = """
    Slack says this app isn’t in that channel. Invite the app to the channel, then try again.
    """

    public static func userFacing(fromVendorDetail detail: String) -> String? {
        let lowered = detail.lowercased()
        if lowered.contains("missing_scope") || lowered.contains("no_permission") {
            return slackBlockedThread
        }
        if lowered.contains("not_in_channel") {
            return botNotInChannel
        }
        if lowered.contains("thread_not_found") {
            return "Slack couldn’t find that thread. It may have been deleted."
        }
        return nil
    }
}
