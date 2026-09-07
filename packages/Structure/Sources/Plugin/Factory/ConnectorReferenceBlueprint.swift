import Foundation

/// Reference patterns injected into connector factory goals so the builder can match
/// reviewer expectations for tests and messaging operations.
public enum ConnectorReferenceBlueprint: Sendable {
    public static func reference(
        vendor: PluginFactoryCreateInput.ConnectorVendor,
        scope: PluginFactoryCreateInput.ConnectorScope
    ) -> String? {
        switch vendor {
        case .slack:
            return slackReference(scope: scope)
        case .telegram:
            return genericReference(vendor: vendor, scope: scope)
        case .whatsapp, .discord, .custom:
            return genericReference(vendor: vendor, scope: scope)
        }
    }

    private static func slackReference(scope: PluginFactoryCreateInput.ConnectorScope) -> String {
        let ops = PluginFactoryCreateInput.ConnectorScope.fullSync.requiredMessagingOps
        var parts = [
            """
            Reference Slack connector blueprint (adapt ids and bodies; do not copy credentials):
            - plugin_id: slack-connection (or a new unused id)
            - secrets: [{id: bot_token, label: Bot Token, kind: token}]
            - messaging_ops: \(ops.joined(separator: ", "))
            - Use conversations.list for sync_threads when implemented
            - Only emit conversations the bot token can access; skip channels where is_member is false
            - If conversations.list returns ok false, emit title/summary with the vendor error; do not emit threads: []
            - Use conversations.history for channel poll_inbox; conversations.replies when params.parent_vendor_message_id or thread_ts is set
            - Channel history with oldest/since must set inclusive=true so the parent message (and its reply_count) is returned
            - Use chat.postMessage for send_message (include thread_ts when sending a reply)
            """,
        ]
        parts.append(scope.slackTestFixtureGuide)
        return parts.joined(separator: "\n\n")
    }

    private static func genericReference(
        vendor: PluginFactoryCreateInput.ConnectorVendor,
        scope: PluginFactoryCreateInput.ConnectorScope
    ) -> String {
        """
        Reference connector blueprint for \(vendor.displayName):
        - Declare secrets for auth tokens only in the manifest.
        - Implement only these messaging_ops: \(PluginFactoryCreateInput.ConnectorScope.fullSync.requiredMessagingOps.joined(separator: ", ")).
        - test_input_json must include http_results fixtures that exercise every implemented messaging_op through result.emit.
        \(scope.genericTestFixtureGuide)
        """
    }
}

private extension PluginFactoryCreateInput.ConnectorScope {
    var slackTestFixtureGuide: String {
        """
        test_input_json must simulate sync_threads, channel poll_inbox, reply-thread poll_inbox, and send_message:
        {"hops":[
          {"kind":"manual","params":{"messaging_op":"sync_threads"}},
          {"kind":"http_results","http_results":[{"request_id":"sync-1","status":200,"body":"{\\"ok\\":true,\\"channels\\":[{\\"id\\":\\"C123\\",\\"name\\":\\"general\\",\\"is_member\\":true},{\\"id\\":\\"C999\\",\\"name\\":\\"secret\\",\\"is_member\\":false}],\\"response_metadata\\":{\\"next_cursor\\":\\"\\"}}"}],"params":{"messaging_op":"sync_threads"}},
          {"kind":"manual","params":{"messaging_op":"poll_inbox","vendor_thread_id":"C123"}},
          {"kind":"http_results","http_results":[{"request_id":"poll-1","status":200,"body":"{\\"ok\\":true,\\"messages\\":[{\\"type\\":\\"message\\",\\"user\\":\\"U1\\",\\"text\\":\\"hello\\",\\"ts\\":\\"1710000000.000100\\",\\"channel\\":\\"C123\\",\\"reply_count\\":1,\\"thread_ts\\":\\"1710000000.000100\\"}]}"}],"params":{"messaging_op":"poll_inbox","vendor_thread_id":"C123"}},
          {"kind":"manual","params":{"messaging_op":"poll_inbox","vendor_thread_id":"C123","parent_vendor_message_id":"1710000000.000100"}},
          {"kind":"http_results","http_results":[{"request_id":"replies-1","status":200,"body":"{\\"ok\\":true,\\"messages\\":[{\\"type\\":\\"message\\",\\"user\\":\\"U1\\",\\"text\\":\\"hello\\",\\"ts\\":\\"1710000000.000100\\",\\"thread_ts\\":\\"1710000000.000100\\",\\"reply_count\\":1},{\\"type\\":\\"message\\",\\"user\\":\\"U2\\",\\"text\\":\\"hi this is a thread\\",\\"ts\\":\\"1710000002.000100\\",\\"thread_ts\\":\\"1710000000.000100\\"}]}"}],"params":{"messaging_op":"poll_inbox","vendor_thread_id":"C123","parent_vendor_message_id":"1710000000.000100"}},
          {"kind":"message_in_room","params":{"messaging_op":"send_message","vendor_thread_id":"C123","text":"hello"}},
          {"kind":"http_results","http_results":[{"request_id":"send-1","status":200,"body":"{\\"ok\\":true,\\"channel\\":\\"C123\\",\\"ts\\":\\"1710000001.000100\\",\\"message\\":{\\"text\\":\\"hello\\"}}"}],"params":{"messaging_op":"send_message","vendor_thread_id":"C123","text":"hello"}}
        ]}
        Channel poll_inbox result.emit must include messages[] with reply_count on threaded parents.
        Reply poll_inbox must include the root and replies with parent_vendor_message_id on each reply.
        send_message must include sent_message. If sending a reply, chat.postMessage body must include thread_ts.
        test_input_json must be one valid JSON object serialized as a string with properly escaped quotes.
        """
    }

    var genericTestFixtureGuide: String {
        "Include fixtures for sync_threads, channel poll_inbox, reply-thread poll_inbox, and send_message."
    }
}
