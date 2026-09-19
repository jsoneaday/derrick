import Foundation
import Structure

/// Shared Slack connector factory input helpers for live/E2E LLM builds.
/// Not a packaged reference draft — builders must use LiveFactoryBuilder.
public enum SlackConnectorFactoryInput {
    public static let defaultCrawlSummary = """
    Slack Web API chat.postMessage accepts JSON with channel and text. Authenticate with a bot token \
    in Authorization: Bearer. Responses include ok (boolean), channel, ts, and message on success.
    conversations.history returns messages with ts, user, text, and channel.
    conversations.list returns channels with id, name, and is_member.
    conversations.replies returns thread replies when parent_vendor_message_id is set.
    """

    public static func make(
        pluginID: String,
        crawlSummary: String = defaultCrawlSummary,
        userDescription: String = "Send and receive messages in Slack channels I pick from a list."
    ) throws -> PluginFactoryCreateInput {
        PluginFactoryCreateInput.makeConnector(
            vendor: .slack,
            pluginID: pluginID,
            auth: try ConnectorAuthDiscovery.slackBotTokenFallback(crawlSummary: crawlSummary),
            scope: .fullSync,
            userDescription: userDescription
        )
    }
}
