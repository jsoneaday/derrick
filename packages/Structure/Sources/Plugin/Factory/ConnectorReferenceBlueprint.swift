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
        var parts = [
            """
            Reference Slack connector blueprint (adapt ids and bodies; do not copy credentials):
            - plugin_id: slack-connection (or a new unused id)
            - secrets: [{id: bot_token, label: Bot Token, kind: token}]
            - messaging_ops: \(scope.requiredMessagingOps.joined(separator: ", "))
            - Use conversations.list for sync_threads when implemented
            - Only emit conversations the bot token can access; skip channels where is_member is false
            - Use conversations.history (+ conversations.replies for threads when full sync) for poll_inbox
            - Use chat.postMessage for send_message
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
        - Implement only these messaging_ops: \(scope.requiredMessagingOps.joined(separator: ", ")).
        - test_input_json must include http_results fixtures that exercise every implemented messaging_op through result.emit.
        \(scope.genericTestFixtureGuide)
        """
    }
}

private extension PluginFactoryCreateInput.ConnectorScope {
    var slackTestFixtureGuide: String {
        switch self {
        case .sendOnly:
            return """
            test_input_json must simulate send_message only using a hops array, for example:
            {"hops":[
              {"kind":"message_in_room","params":{"messaging_op":"send_message","vendor_thread_id":"C123","text":"hello"}},
              {"kind":"http_results","http_results":[{"request_id":"send-1","status":200,"body":"{\\"ok\\":true,\\"channel\\":\\"C123\\",\\"ts\\":\\"1710000001.000100\\",\\"message\\":{\\"text\\":\\"hello\\"}}"}],"params":{"messaging_op":"send_message","vendor_thread_id":"C123","text":"hello"}}
            ]}
            Use the same request_id in your http.request envelope and http_results fixture.
            Terminal result.emit must include sent_message.vendor_message_id and created_at.
            """
        case .sendAndReceive:
            return """
            test_input_json must simulate sync_threads, poll_inbox, and send_message using separate hop pairs with ONE page each (no sync-2/poll-2 unless fixtures exist):
            {"hops":[
              {"kind":"manual","params":{"messaging_op":"sync_threads"}},
              {"kind":"http_results","http_results":[{"request_id":"sync-1","status":200,"body":"{\\"ok\\":true,\\"channels\\":[{\\"id\\":\\"C123\\",\\"name\\":\\"general\\",\\"is_member\\":true},{\\"id\\":\\"C999\\",\\"name\\":\\"secret\\",\\"is_member\\":false}],\\"response_metadata\\":{\\"next_cursor\\":\\"\\"}}"}],"params":{"messaging_op":"sync_threads"}},
              {"kind":"manual","params":{"messaging_op":"poll_inbox","vendor_thread_id":"C123"}},
              {"kind":"http_results","http_results":[{"request_id":"poll-1","status":200,"body":"{\\"ok\\":true,\\"messages\\":[{\\"type\\":\\"message\\",\\"user\\":\\"U1\\",\\"text\\":\\"hello\\",\\"ts\\":\\"1710000000.000100\\",\\"channel\\":\\"C123\\"}]}"}],"params":{"messaging_op":"poll_inbox","vendor_thread_id":"C123"}},
              {"kind":"message_in_room","params":{"messaging_op":"send_message","vendor_thread_id":"C123","text":"hello"}},
              {"kind":"http_results","http_results":[{"request_id":"send-1","status":200,"body":"{\\"ok\\":true,\\"channel\\":\\"C123\\",\\"ts\\":\\"1710000001.000100\\",\\"message\\":{\\"text\\":\\"hello\\"}}"}],"params":{"messaging_op":"send_message","vendor_thread_id":"C123","text":"hello"}}
            ]}
            sync_threads result.emit must include threads[] with vendor_thread_id and human title; poll_inbox must include messages[]; send_message must include sent_message.
            """
        case .fullSync:
            return """
            test_input_json must simulate sync_threads, poll_inbox, and send_message using separate hop pairs:
            {"hops":[
              {"kind":"manual","params":{"messaging_op":"sync_threads"}},
              {"kind":"http_results","http_results":[{"request_id":"sync-1","status":200,"body":"{\\"ok\\":true,\\"channels\\":[{\\"id\\":\\"C123\\",\\"name\\":\\"general\\",\\"is_member\\":true},{\\"id\\":\\"C999\\",\\"name\\":\\"secret\\",\\"is_member\\":false}],\\"response_metadata\\":{\\"next_cursor\\":\\"\\"}}"}],"params":{"messaging_op":"sync_threads"}},
              {"kind":"manual","params":{"messaging_op":"poll_inbox"}},
              {"kind":"http_results","http_results":[{"request_id":"poll-1","status":200,"body":"{\\"ok\\":true,\\"messages\\":[{\\"type\\":\\"message\\",\\"user\\":\\"U1\\",\\"text\\":\\"hello\\",\\"ts\\":\\"1710000000.000100\\",\\"channel\\":\\"C123\\"}]}"}],"params":{"messaging_op":"poll_inbox"}},
              {"kind":"message_in_room","params":{"messaging_op":"send_message","vendor_thread_id":"C123","text":"hello"}},
              {"kind":"http_results","http_results":[{"request_id":"send-1","status":200,"body":"{\\"ok\\":true,\\"channel\\":\\"C123\\",\\"ts\\":\\"1710000001.000100\\",\\"message\\":{\\"text\\":\\"hello\\"}}"}],"params":{"messaging_op":"send_message","vendor_thread_id":"C123","text":"hello"}}
            ]}
            sync_threads result.emit must include threads[]; poll_inbox must include messages[]; send_message must include sent_message.
            test_input_json must be one valid JSON object serialized as a string with properly escaped quotes.
            """
        }
    }

    var genericTestFixtureGuide: String {
        switch self {
        case .sendOnly:
            return "Include fixtures for send_message success and auth failure only."
        case .sendAndReceive:
            return "Include fixtures for sync_threads (label→ID mapping), poll_inbox, and send_message."
        case .fullSync:
            return "Include fixtures for sync_threads, poll_inbox (with pagination), and send_message."
        }
    }
}
