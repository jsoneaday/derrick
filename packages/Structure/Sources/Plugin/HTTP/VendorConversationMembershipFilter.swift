import Foundation

/// Drops vendor conversation-list entries the saved secret cannot access
/// before guest plugins see the HTTP body.
public enum VendorConversationMembershipFilter: Sendable {
    public static func sanitizedBody(urlString: String, body: String) -> String {
        guard isConversationListURL(urlString) else { return body }
        guard let data = body.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return body
        }
        var changed = false
        for key in ["channels", "ims", "groups"] {
            guard let items = json[key] as? [[String: Any]] else { continue }
            let kept = items.filter(isAccessibleConversation)
            if kept.count != items.count {
                json[key] = kept
                changed = true
            }
        }
        guard changed else { return body }
        guard let encoded = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: encoded, encoding: .utf8)
        else {
            return body
        }
        return text
    }

    private static func isConversationListURL(_ urlString: String) -> Bool {
        let lowered = urlString.lowercased()
        return lowered.contains("conversations.list")
            || lowered.contains("users.conversations")
    }

    private static func isAccessibleConversation(_ channel: [String: Any]) -> Bool {
        if let member = channel["is_member"] as? Bool, member == false {
            return false
        }
        if let accessible = channel["accessible"] as? Bool, accessible == false {
            return false
        }
        return true
    }
}
