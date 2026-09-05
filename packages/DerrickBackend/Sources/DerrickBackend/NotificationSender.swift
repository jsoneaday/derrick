import Foundation
import Structure

/// Client API: post a user notification via the Daemon (or in-process when already the Daemon).
public enum NotificationSender: Sendable {
    /// When `true`, this process posts directly (Daemon). Otherwise XPC to Daemon.
    nonisolated(unsafe) public static var postsLocally: Bool = false

    public static func post(_ request: UserNotificationRequest) async throws {
        if postsLocally {
            try await NotificationPostingService.shared.post(request)
            return
        }
        try await DaemonClient.shared.postUserNotification(request)
    }
}
