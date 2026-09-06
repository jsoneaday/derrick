import Foundation
import Structure

/// Inbound connector messages → Daemon UserNotifications when the main UI is not running.
public enum MessagingInboundNotifier: Sendable {
    /// Posts one banner per conversation that received new inbound mail this poll.
    /// No-op while Derrick is open (badges + live refresh already cover that).
    public static func notifyNewInbound(
        _ rows: [MessagingPersistResult],
        uiIsInteractive: Bool = DerrickUIPresence.isInteractiveUIRunning()
    ) async {
        guard !uiIsInteractive else { return }
        for request in notificationRequests(from: rows) {
            do {
                try await NotificationSender.post(request)
            } catch {
                fputs(
                    "[MessagingInboundNotifier] post failed id=\(request.id): \(error.localizedDescription)\n",
                    stderr
                )
            }
        }
    }

    static func notificationRequests(from rows: [MessagingPersistResult]) -> [UserNotificationRequest] {
        let inbound = rows.filter {
            $0.inserted && $0.message.direction == .inbound && !$0.thread.muted
        }
        let grouped = Dictionary(grouping: inbound, by: \.thread.id)
        return grouped.keys.sorted().compactMap { threadID in
            guard let group = grouped[threadID], let last = group.last else {
                return nil
            }
            return request(for: group, last: last)
        }
    }

    private static func request(
        for group: [MessagingPersistResult],
        last: MessagingPersistResult
    ) -> UserNotificationRequest {
        let thread = last.thread
        let preview = truncated(last.message.body, limit: 180)
        let sender = last.message.sender.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastBit = sender.isEmpty ? preview : "\(sender): \(preview)"
        let body: String
        if group.count == 1 {
            body = lastBit.isEmpty ? "New message" : lastBit
        } else if lastBit.isEmpty {
            body = "\(group.count) new messages"
        } else {
            body = "\(group.count) new messages. \(lastBit)"
        }
        let title = thread.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return UserNotificationRequest(
            id: "derrick.messaging.\(thread.pluginID).\(thread.id)",
            kind: .messagingMessage,
            title: title.isEmpty ? "Derrick" : title,
            body: body,
            threadIdentifier: "derrick.messaging.\(thread.pluginID).\(thread.id)",
            timeSensitive: false,
            userInfo: [
                UserNotificationUserInfoKey.kind.rawValue: UserNotificationKind.messagingMessage.rawValue,
                UserNotificationUserInfoKey.pluginID.rawValue: thread.pluginID,
                UserNotificationUserInfoKey.threadID.rawValue: thread.id,
                UserNotificationUserInfoKey.messagingMessageID.rawValue: last.message.id,
            ]
        )
    }

    private static func truncated(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }
}
