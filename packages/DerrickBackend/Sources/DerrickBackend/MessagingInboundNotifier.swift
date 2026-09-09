import Foundation
import Structure

/// Inbound connector messages → macOS notifications (open or closed UI).
public enum MessagingInboundNotifier: Sendable {
    /// Posts one OS banner per conversation that received new inbound mail this poll.
    public static func notifyNewInbound(
        _ rows: [MessagingPersistResult],
        uiIsInteractive: Bool = DerrickUIPresence.isInteractiveUIRunning()
    ) async {
        _ = uiIsInteractive
        let enriched = await enrichDisplayNames(rows)
        let suppressedPluginID = DerrickMessagingForegroundPresence.pluginIDForSuppressedOSNotifications()
        for request in notificationRequests(from: enriched, suppressingPluginID: suppressedPluginID) {
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

    static func notificationRequests(
        from rows: [MessagingPersistResult],
        suppressingPluginID: String? = nil
    ) -> [UserNotificationRequest] {
        let inbound = rows.filter {
            $0.inserted && $0.message.direction == .inbound && !$0.thread.muted
        }
        let suppressed = suppressingPluginID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let notifiable = inbound.filter { row in
            suppressed.isEmpty || row.thread.pluginID != suppressed
        }
        let replies = notifiable.filter(\.message.isReply)
        let roots = notifiable.filter { !$0.message.isReply }

        var requests: [UserNotificationRequest] = []
        let rootGrouped = Dictionary(grouping: roots, by: \.thread.id)
        for threadID in rootGrouped.keys.sorted() {
            guard let group = rootGrouped[threadID], let last = group.last else { continue }
            requests.append(request(for: group, last: last))
        }
        for reply in replies.sorted(by: { $0.message.createdAt < $1.message.createdAt }) {
            requests.append(request(for: [reply], last: reply))
        }
        return requests
    }

    private static func enrichDisplayNames(_ rows: [MessagingPersistResult]) async -> [MessagingPersistResult] {
        var enriched: [MessagingPersistResult] = []
        for row in rows {
            let sender = await MessagingSenderDisplayName.resolve(
                pluginID: row.thread.pluginID,
                sender: row.message.sender
            )
            guard sender != row.message.sender else {
                enriched.append(row)
                continue
            }
            enriched.append(
                MessagingPersistResult(
                    inserted: row.inserted,
                    message: MessagingMessageDTO(
                        id: row.message.id,
                        threadID: row.message.threadID,
                        vendorMessageID: row.message.vendorMessageID,
                        direction: row.message.direction,
                        sender: sender,
                        body: row.message.body,
                        createdAt: row.message.createdAt,
                        parentVendorMessageID: row.message.parentVendorMessageID,
                        replyCount: row.message.replyCount
                    ),
                    thread: row.thread
                )
            )
        }
        return enriched
    }

    private static func request(
        for group: [MessagingPersistResult],
        last: MessagingPersistResult
    ) -> UserNotificationRequest {
        let thread = last.thread
        let message = last.message
        let isReply = message.isReply
        let preview = truncated(message.body, limit: 180)
        let sender = message.sender.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastBit = MessagingInboundNotificationCopy.previewBody(
            sender: sender,
            body: preview,
            isReply: isReply
        )
        let body: String
        if group.count == 1 {
            body = lastBit
        } else if lastBit.isEmpty {
            body = "\(group.count) new messages"
        } else {
            body = "\(group.count) new messages. \(lastBit)"
        }
        let channelTitle = thread.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = channelTitle.isEmpty ? "Derrick" : channelTitle
        let subtitle = isReply ? "Thread reply" : nil
        let threadIdentifier: String
        if isReply, let parent = message.parentVendorMessageID {
            threadIdentifier = "derrick.messaging.\(thread.pluginID).\(thread.id).\(parent)"
        } else {
            threadIdentifier = "derrick.messaging.\(thread.pluginID).\(thread.id)"
        }
        var userInfo: [String: String] = [
            UserNotificationUserInfoKey.kind.rawValue: UserNotificationKind.messagingMessage.rawValue,
            UserNotificationUserInfoKey.pluginID.rawValue: thread.pluginID,
            UserNotificationUserInfoKey.threadID.rawValue: thread.id,
            UserNotificationUserInfoKey.messagingMessageID.rawValue: message.id,
        ]
        if let parent = message.parentVendorMessageID {
            userInfo[UserNotificationUserInfoKey.messagingParentVendorMessageID.rawValue] = parent
        }
        return UserNotificationRequest(
            id: "derrick.messaging.\(thread.pluginID).\(message.id)",
            kind: .messagingMessage,
            title: title,
            body: body,
            subtitle: subtitle,
            threadIdentifier: threadIdentifier,
            timeSensitive: false,
            userInfo: userInfo
        )
    }

    private static func truncated(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }
}
