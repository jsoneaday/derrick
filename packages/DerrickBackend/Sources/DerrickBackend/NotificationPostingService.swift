import AppKit
import Foundation
import ServiceContracts
import UserNotifications

/// Sole UserNotifications poster. Runs only inside the Daemon process.
///
/// Prefer `UNUserNotificationCenter`. If TCC blocks the LSUIElement agent (common for
/// launchd-started helpers), fall back to legacy `NSUserNotification`, which still
/// delivers from LaunchAgents on macOS.
public actor NotificationPostingService {
    public static let shared = NotificationPostingService()

    private var prepared = false

    public func prepare() async {
        guard !prepared else { return }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        fputs("[derrickd] notification auth status=\(status.rawValue)\n", stderr)
        if status == .notDetermined {
            await MainActor.run {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                fputs("[derrickd] notification auth granted=\(granted)\n", stderr)
            } catch {
                fputs("[derrickd] notification auth request failed: \(error.localizedDescription)\n", stderr)
            }
            await MainActor.run {
                NSApp.setActivationPolicy(.accessory)
            }
        } else if status == .denied {
            fputs(
                "[derrickd] UN auth denied — will use legacy NSUserNotification fallback\n",
                stderr
            )
        }
        prepared = true
    }

    public func post(_ request: UserNotificationRequest) async throws {
        await prepare()
        do {
            try await postModern(request)
            return
        } catch {
            fputs(
                "[derrickd] UN post failed (\(error.localizedDescription)) — trying legacy NSUserNotification\n",
                stderr
            )
        }
        try await postLegacy(request)
    }

    private func postModern(_ request: UserNotificationRequest) async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        case .denied:
            throw NotificationPostingError.denied
        case .notDetermined:
            throw NotificationPostingError.notAuthorized
        @unknown default:
            throw NotificationPostingError.notAuthorized
        }

        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        if let subtitle = request.subtitle, !subtitle.isEmpty {
            content.subtitle = subtitle
        }
        content.sound = .default
        if #available(macOS 12.0, *) {
            content.interruptionLevel = request.timeSensitive ? .timeSensitive : .active
        }
        content.userInfo = makeUserInfo(request)
        if let thread = request.threadIdentifier {
            content.threadIdentifier = thread
        }

        let unRequest = UNNotificationRequest(identifier: request.id, content: content, trigger: nil)
        try await center.add(unRequest)
        fputs("[derrickd] UN notification posted id=\(request.id) kind=\(request.kind.rawValue)\n", stderr)
    }

    private func postLegacy(_ request: UserNotificationRequest) async throws {
        let info = makeUserInfo(request)
        await MainActor.run {
            let note = NSUserNotification()
            note.title = request.title
            note.subtitle = request.subtitle
            note.informativeText = request.body
            note.soundName = NSUserNotificationDefaultSoundName
            note.identifier = request.id
            note.userInfo = info
            NSUserNotificationCenter.default.deliver(note)
            fputs(
                "[derrickd] legacy NSUserNotification delivered id=\(request.id) kind=\(request.kind.rawValue)\n",
                stderr
            )
        }
    }

    nonisolated private func makeUserInfo(_ request: UserNotificationRequest) -> [String: Any] {
        var info = request.userInfo.reduce(into: [String: Any]()) { partial, item in
            partial[item.key] = item.value
        }
        info[UserNotificationUserInfoKey.kind.rawValue] = request.kind.rawValue
        switch request.kind {
        case .jobResult:
            info["kind"] = "job-result"
            if let id = request.userInfo[UserNotificationUserInfoKey.jobResultID.rawValue] {
                info["jobResultID"] = id
            }
        case .hitlApproval:
            info["kind"] = "hitl-approval"
            if let id = request.userInfo[UserNotificationUserInfoKey.approvalID.rawValue] {
                info["approvalID"] = id
            }
        case .notice:
            break
        }
        return info
    }
}

public enum NotificationPostingError: Error, LocalizedError, Sendable {
    case denied
    case notAuthorized

    public var errorDescription: String? {
        switch self {
        case .denied: return "Notification permission denied for derrick.ui.Daemon — enable in System Settings → Notifications → DerrickDaemon"
        case .notAuthorized: return "Notification permission not granted for derrick.ui.Daemon"
        }
    }
}
