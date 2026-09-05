import Foundation
import Structure
import UserNotifications

/// Authorization helper for the main UI app (HITL banners are posted by derrickd).
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
        // Notification taps for job results and HITL are handled in derrickd.
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
}
