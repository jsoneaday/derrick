import Foundation

/// Cross-process: which messaging connector the interactive UI is showing.
///
/// derrickd skips macOS banners for that connector while Derrick is frontmost
/// on Messaging, so the UI can show a short in-app banner instead.
public enum DerrickMessagingForegroundPresence: Sendable {
    private static let fileName = "messaging_foreground.json"

    private struct Record: Codable, Sendable {
        let pid: Int32
        let pluginID: String?
        let isMessagingWorkspace: Bool
        let isFrontmost: Bool
    }

    public static func sync(
        isMessagingWorkspace: Bool,
        pluginID: String?,
        isFrontmost: Bool,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        guard let url = fileURL() else { return }
        let trimmed = pluginID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = Record(
            pid: pid,
            pluginID: (trimmed?.isEmpty == false) ? trimmed : nil,
            isMessagingWorkspace: isMessagingWorkspace,
            isFrontmost: isFrontmost
        )
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func clear() {
        guard let url = fileURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Plugin ID whose inbound OS banners should be suppressed.
    public static func pluginIDForSuppressedOSNotifications(
        excludingPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> String? {
        guard let record = readRecord() else { return nil }
        guard record.pid != excludingPID else { return nil }
        guard isProcessAlive(record.pid) else { return nil }
        guard record.isMessagingWorkspace, record.isFrontmost else { return nil }
        let pluginID = record.pluginID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return pluginID.isEmpty ? nil : pluginID
    }

    private static func readRecord() -> Record? {
        guard let url = fileURL(),
              let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private static func fileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: DerrickAppSupport.applicationGroupIdentifier)?
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }
}
