import Foundation
import ServiceContracts
import UserNotifications

/// Posts macOS user notifications from the **main UI app** for remaining HITL paths.
/// Job-completion banners are posted by derrickd (`NotificationSender` / `JobResultNotifier`).
/// Background helpers and XPC services must not call this.
enum UserNotificationPoster {
    enum PostError: Error, LocalizedError {
        case notMainApp
        case notAuthorized
        case denied(UNAuthorizationStatus)
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .notMainApp:
                return "Not the main UI app process"
            case .notAuthorized:
                return "Notification authorization not granted"
            case .denied(let status):
                return "Notifications denied (status=\(status.rawValue))"
            case .underlying(let error):
                return error.localizedDescription
            }
        }
    }

    static var isMainAppProcess: Bool {
        (Bundle.main.bundleIdentifier ?? "") == DerrickServiceID.ui.rawValue
    }

    @MainActor
    static func configureDelegateIfNeeded() {
        guard isMainAppProcess else { return }
        UNUserNotificationCenter.current().delegate = UserNotificationCenterDelegate.shared
    }

    @MainActor
    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    @MainActor
    @discardableResult
    static func requestAuthorizationIfNeeded() async -> Bool {
        guard isMainAppProcess else { return false }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            break
        @unknown default:
            break
        }
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            fputs("[UserNotificationPoster] auth request failed: \(error.localizedDescription)\n", stderr)
            return false
        }
    }

    @MainActor
    static func post(
        identifier: String,
        title: String,
        body: String,
        subtitle: String? = nil,
        categoryIdentifier: String? = nil,
        userInfo: [AnyHashable: Any] = [:],
        threadIdentifier: String? = nil,
        timeSensitive: Bool = false
    ) async -> Result<Void, PostError> {
        guard isMainAppProcess else {
            return .failure(.notMainApp)
        }
        let status = await authorizationStatus()
        switch status {
        case .authorized, .provisional, .ephemeral:
            break
        case .notDetermined:
            guard await requestAuthorizationIfNeeded() else {
                return .failure(.notAuthorized)
            }
        case .denied:
            return .failure(.denied(status))
        @unknown default:
            return .failure(.notAuthorized)
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let subtitle, !subtitle.isEmpty {
            content.subtitle = subtitle
        }
        content.sound = .default
        if #available(macOS 12.0, *) {
            content.interruptionLevel = timeSensitive ? .timeSensitive : .active
        }
        if let categoryIdentifier {
            content.categoryIdentifier = categoryIdentifier
        }
        // Unique thread per notification — shared threads collapse banners into Notification Center.
        if let threadIdentifier {
            content.threadIdentifier = threadIdentifier
        }
        for (key, value) in userInfo {
            content.userInfo[key] = value
        }

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                UNUserNotificationCenter.current().add(request) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            return .success(())
        } catch {
            return .failure(.underlying(error))
        }
    }
}

final class UserNotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = UserNotificationCenterDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let kind = userInfo[DerrickNotificationPayload.kindKey] as? String
            ?? userInfo[UserNotificationUserInfoKey.kind.rawValue] as? String
        let approvalID = userInfo[DerrickNotificationPayload.approvalIDKey] as? String
            ?? userInfo[UserNotificationUserInfoKey.approvalID.rawValue] as? String
        // Finish the system callback first; never do AppKit work on this stack.
        completionHandler()
        DispatchQueue.main.async {
            Task { @MainActor in
                await DerrickNotificationService.shared.handleResponse(
                    actionIdentifier: actionID,
                    kind: kind,
                    approvalID: approvalID
                )
            }
        }
    }
}
