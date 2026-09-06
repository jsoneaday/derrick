import Foundation

/// Scope and manifest facts used by deterministic factory draft validation.
public enum PluginFactoryValidationExpectations: Sendable {
    public static let knownMessagingOps = ["send_message", "poll_inbox", "sync_threads"]

    public static func requiredMessagingOps(from userGoal: String?) -> [String] {
        guard let userGoal, !userGoal.isEmpty else { return [] }
        if let declared = parseDeclaredMessagingOps(from: userGoal), !declared.isEmpty {
            return declared
        }
        if userGoal.localizedCaseInsensitiveContains("send_message only") {
            return ["send_message"]
        }
        if userGoal.localizedCaseInsensitiveContains("Scope: sync_threads, send_message, and poll_inbox")
            || userGoal.localizedCaseInsensitiveContains("sync_threads, send_message, and poll_inbox") {
            return ["sync_threads", "poll_inbox", "send_message"]
        }
        if userGoal.localizedCaseInsensitiveContains("Scope: send_message and poll_inbox")
            || userGoal.localizedCaseInsensitiveContains("send_message and poll_inbox") {
            return ["poll_inbox", "send_message"]
        }
        if userGoal.localizedCaseInsensitiveContains("sync_threads, poll_inbox, and send_message") {
            return ["sync_threads", "poll_inbox", "send_message"]
        }
        return []
    }

    public static func messagingOps(fromManifestJSON json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let extensions = object["extensions"] as? [String: Any],
              let derrick = extensions[PluginContract.derrickExtensionNamespace] as? [String: Any],
              let raw = derrick["messaging_ops"] as? [Any] else {
            return []
        }
        return raw.compactMap { value in
            guard let string = value as? String else { return nil }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// Send-only connectors post to a channel ID without poll or thread sync.
    public static func isSendOnlyConnector(manifestJSON: String) -> Bool {
        let ops = Set(messagingOps(fromManifestJSON: manifestJSON))
        return ops.contains("send_message")
            && !ops.contains("poll_inbox")
            && !ops.contains("sync_threads")
    }

    public static func supportsSyncThreads(manifestJSON: String) -> Bool {
        messagingOps(fromManifestJSON: manifestJSON).contains("sync_threads")
    }

    /// Connectors with sync_threads expose label→vendor ID mappings for the host channel picker.
    public static func supportsThreadDiscovery(manifestJSON: String) -> Bool {
        supportsSyncThreads(manifestJSON: manifestJSON)
    }

    public static func supportsPollInbox(manifestJSON: String) -> Bool {
        messagingOps(fromManifestJSON: manifestJSON).contains("poll_inbox")
    }

    private static func parseDeclaredMessagingOps(from userGoal: String) -> [String]? {
        guard let line = userGoal
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { $0.contains("Declare messaging_ops:") }) else {
            return nil
        }
        let text = String(line)
        let pattern = #""([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        let ops = matches.compactMap { match -> String? in
            guard match.numberOfRanges > 1,
                  let opRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[opRange])
        }
        return ops.isEmpty ? nil : ops
    }
}
