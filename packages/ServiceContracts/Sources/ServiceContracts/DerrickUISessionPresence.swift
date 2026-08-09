import Foundation

/// Cross-process signal: an interactive `derrick.ui` session finished bootstrap and is ready for chat.
///
/// Daemon uses this (not `NSRunningApplication`) to decide whether a notification tap should wake the
/// existing UI or spawn a panel-only presenter.
public enum DerrickUISessionPresence: Sendable {
    private static let fileName = "interactive_ui_session.json"

    private struct Record: Codable, Sendable {
        let pid: Int32
        let markedAt: Date
    }

    public static func markInteractiveSessionActive(pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        guard let url = sessionFileURL() else { return }
        let record = Record(pid: pid, markedAt: .now)
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func clearInteractiveSession() {
        guard let url = sessionFileURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// True when another live process has marked an interactive session since last clear.
    public static func isInteractiveSessionActive(
        excludingPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> Bool {
        guard let record = readRecord() else { return false }
        guard record.pid != excludingPID else { return false }
        return isProcessAlive(record.pid)
    }

    // MARK: - Private

    private static func readRecord() -> Record? {
        guard let url = sessionFileURL(),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private static func sessionFileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: DerrickAppSupport.applicationGroupIdentifier)?
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }
}
