import Foundation

/// User-facing notification text for inbound connector messages.
public enum MessagingInboundNotificationCopy: Sendable {
    /// Slack-style opaque actor IDs (member, bot, channel, group) are not human-readable.
    public static func isOpaqueVendorActorID(_ sender: String) -> Bool {
        let trimmed = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8, let first = trimmed.first else { return false }
        guard "UWBCG".contains(first) else { return false }
        return trimmed.dropFirst().allSatisfy { $0.isUppercase || $0.isNumber }
    }

    public static func previewBody(
        sender: String,
        body: String,
        isReply: Bool = false
    ) -> String {
        let preview = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSender = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = isReply ? "New thread reply" : "New message"

        if trimmedSender.isEmpty || isOpaqueVendorActorID(trimmedSender) {
            return preview.isEmpty ? fallback : preview
        }
        if preview.isEmpty {
            return trimmedSender
        }
        return "\(trimmedSender): \(preview)"
    }
}
