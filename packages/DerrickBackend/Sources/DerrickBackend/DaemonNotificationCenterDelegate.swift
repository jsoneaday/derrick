import AppKit
import Foundation
import ServiceContracts
import UserNotifications

/// Handles notification taps in the Daemon process (poster), then wakes the UI.
public final class DaemonNotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = DaemonNotificationCenterDelegate()

    public func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let kind = info[UserNotificationUserInfoKey.kind.rawValue] as? String
            ?? info["kind"] as? String
        let jobResultID = info[UserNotificationUserInfoKey.jobResultID.rawValue] as? String
            ?? info["jobResultID"] as? String
        completionHandler()
        guard kind == UserNotificationKind.jobResult.rawValue || kind == "job-result",
              let jobResultID,
              !jobResultID.isEmpty
        else {
            fputs("[derrickd] notification tap ignored kind=\(kind ?? "nil")\n", stderr)
            return
        }
        // Leave the UN callback stack before AppKit / NSWorkspace work.
        DispatchQueue.main.async {
            Task {
                await DaemonUILauncher.openJobResult(id: jobResultID)
            }
        }
    }
}

/// Opens the host UI to present a job result after a notification tap.
public enum DaemonUILauncher: Sendable {
    // Debounce only — not a security boundary.
    nonisolated(unsafe) private static var lastOpenedID: String?
    nonisolated(unsafe) private static var lastOpenedAt: Date = .distantPast

    public static func openJobResult(id: String) async {
        // Debounce: daemon restarts / UN redelivery must not spawn panel spam.
        let skip = (lastOpenedID == id && Date().timeIntervalSince(lastOpenedAt) < 45)
        if skip {
            fputs("[derrickd] present-job-result skipped (debounce) \(id)\n", stderr)
            return
        }
        lastOpenedID = id
        lastOpenedAt = Date()

        // Pending file first — UI can present even if argv is dropped by Launch Services.
        DerrickNotificationLaunch.postShowJobResult(id)

        let uiApps = NSRunningApplication
            .runningApplications(withBundleIdentifier: DerrickServiceID.ui.rawValue)
        // Any live derrick.ui process should consume the Darwin wake in-process.
        // Spawning `open -n` while the main UI is up races the pending-result file and
        // often produces an invisible accessory panel.
        if !uiApps.isEmpty {
            fputs("[derrickd] present-job-result wake \(id) (UI already running)\n", stderr)
            return
        }

        guard let uiURL = locateUIApp() else {
            fputs("[derrickd] cannot locate derrick.ui to present job result \(id)\n", stderr)
            return
        }
        // Prefer `/usr/bin/open -n --args` so argv always reaches a fresh process
        // (NSWorkspace often ignores arguments when any derrick.ui instance exists).
        openViaOpenCLI(uiURL: uiURL, resultID: id)
    }

    /// `open -n --args` is the most reliable way to pass argv to a GUI app.
    private static func openViaOpenCLI(uiURL: URL, resultID: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [
            "-n",
            "-a", uiURL.path,
            "--args",
            DerrickNotificationLaunch.showJobResultArgument,
            resultID,
        ]
        do {
            try proc.run()
            fputs("[derrickd] /usr/bin/open -n panel-only for \(resultID)\n", stderr)
        } catch {
            fputs("[derrickd] /usr/bin/open failed: \(error.localizedDescription)\n", stderr)
        }
    }

    /// Deprecated: jobs run in-process inside derrickd. Kept as a no-op for ABI stability.
    public static func wakeJobWorker() async {
        fputs("[derrickd] wakeJobWorker ignored — jobs run in-process\n", stderr)
    }

    private static func locateUIApp() -> URL? {
        // Prefer the host app that embeds this LoginItem (matches the Debug build that
        // launched derrickd), not whatever Launch Services ranks first among DerivedData copies.
        let loginItemHost = Bundle.main.bundleURL
            .deletingLastPathComponent() // LoginItems
            .deletingLastPathComponent() // Library
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // ui.app
        if loginItemHost.pathExtension == "app",
           Bundle(url: loginItemHost)?.bundleIdentifier == DerrickServiceID.ui.rawValue {
            return loginItemHost
        }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: DerrickServiceID.ui.rawValue) {
            return url
        }

        var bundle = Bundle.main.bundleURL
        for _ in 0..<8 {
            if bundle.pathExtension == "app",
               Bundle(url: bundle)?.bundleIdentifier == DerrickServiceID.ui.rawValue {
                return bundle
            }
            let parent = bundle.deletingLastPathComponent()
            if parent.path == bundle.path { break }
            bundle = parent
        }
        return nil
    }
}
