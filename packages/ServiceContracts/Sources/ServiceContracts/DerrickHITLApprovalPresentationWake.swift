import Foundation

/// Cross-process wake to present a HITL Allow/Deny sheet (sandbox-safe: app group file + Darwin notify).
public enum DerrickHITLApprovalPresentationWake: Sendable {
    public static let darwinName = "derrick.ui.presentHITLApproval"
    public static let localNotificationName = Notification.Name("derrick.ui.presentHITLApproval.local")
    private static let pendingFileName = "pending_hitl_approval_presentation.txt"

    public static func post(approvalID: String) {
        guard !approvalID.isEmpty else { return }
        if let url = pendingFileURL() {
            try? approvalID.data(using: .utf8)?.write(to: url, options: .atomic)
        }
        let name = CFNotificationName(darwinName as CFString)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            name,
            nil,
            nil,
            true
        )
    }

    public static func peekPendingApprovalID() -> String? {
        readPendingApprovalID()
    }

    public static func takePendingApprovalID() -> String? {
        guard let id = readPendingApprovalID(), let url = pendingFileURL() else { return nil }
        try? FileManager.default.removeItem(at: url)
        return id
    }

    private static func readPendingApprovalID() -> String? {
        guard let url = pendingFileURL() else { return nil }
        guard let data = try? Data(contentsOf: url),
              let id = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty
        else {
            return nil
        }
        return id
    }

    private static func pendingFileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: DerrickAppSupport.applicationGroupIdentifier)?
            .appendingPathComponent(pendingFileName, isDirectory: false)
    }
}
