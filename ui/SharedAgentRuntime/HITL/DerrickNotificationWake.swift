import AppKit
import Foundation
import ServiceContracts

/// Wakes the main UI process to poll SQLite and post notifications when it is not running.
public enum DerrickNotificationWake {
    public static func wakeUIIfNeeded() {
        guard !isMainAppRunning() else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-g", "-j", "-n",
            "-b", DerrickServiceID.ui.rawValue,
            "--args",
            DerrickNotificationLaunch.pollArgument
        ]
        do {
            try process.run()
            fputs("[DerrickNotificationWake] launched UI poll\n", stderr)
        } catch {
            fputs("[DerrickNotificationWake] open failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private static func isMainAppRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: DerrickServiceID.ui.rawValue)
            .isEmpty
    }
}
