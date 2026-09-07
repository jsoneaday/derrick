import Foundation
import Plugin
import Structure

/// Supplies known-good Slack connector drafts for end-to-end messaging verification.
public actor E2EFactoryBuilder: PluginFactoryBuilder {
    private let scope: PluginFactoryCreateInput.ConnectorScope

    public init(scope: PluginFactoryCreateInput.ConnectorScope) {
        self.scope = scope
    }

    public func makeDraft(_ request: PluginFactoryBuilderRequest) async throws -> PluginFactoryDraft {
        fputs("[E2E] building reference Slack draft for \(scope.rawValue)\n", stderr)
        return ReferenceSlackConnectorDraft.make(scope: scope, userGoal: request.userGoal)
    }
}

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
