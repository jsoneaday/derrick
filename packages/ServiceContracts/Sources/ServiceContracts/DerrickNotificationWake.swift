import Foundation

/// Wakes the main UI process to poll SQLite and post user notifications when it is not running.
public enum DerrickNotificationWake {
    /// Launches a short-lived UI instance (`--derrick-notify-poll`) to post pending notifications.
    /// Safe to call repeatedly — SQLite claims are atomic and duplicate polls are no-ops.
    public static func wakeUIForNotificationPoll(hostAppURL: URL? = nil) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        let appURL = hostAppURL ?? resolvedHostAppURL()
        if let appURL {
            process.arguments = [
                "-g", "-n",
                appURL.path,
                "--args",
                DerrickNotificationLaunch.pollArgument
            ]
        } else {
            process.arguments = [
                "-g", "-n",
                "-b", DerrickServiceID.ui.rawValue,
                "--args",
                DerrickNotificationLaunch.pollArgument
            ]
        }
        do {
            try process.run()
            fputs("[DerrickNotificationWake] launched UI poll\n", stderr)
        } catch {
            fputs("[DerrickNotificationWake] open failed: \(error.localizedDescription)\n", stderr)
        }
    }

    /// When the UI is already running it polls on Darwin signal; otherwise wake a poll instance.
    public static func wakeUIIfNeeded(hostAppURL: URL? = nil) {
        guard !isHostUIApplicationRunning() else { return }
        wakeUIForNotificationPoll(hostAppURL: hostAppURL)
    }

    public static func isHostUIApplicationRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "application id \"\(DerrickServiceID.ui.rawValue)\" is running"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return output == "true"
        } catch {
            fputs("[DerrickNotificationWake] running check failed: \(error.localizedDescription)\n", stderr)
            return false
        }
    }

    /// Best-effort `ui.app` URL from this process (XPC → walk up; tool → Contents/MacOS parent).
    public static func resolvedHostAppURL() -> URL? {
        var url = Bundle.main.bundleURL
        for _ in 0..<6 {
            if url.pathExtension == "app" {
                return url
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        // JobKeepAlive / tools: .../ui.app/Contents/MacOS/<exe>
        if CommandLine.arguments.first.map({ URL(fileURLWithPath: $0) }) != nil {
            var exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            for _ in 0..<4 {
                if exe.pathExtension == "app" { return exe }
                exe = exe.deletingLastPathComponent()
            }
        }
        return nil
    }
}
