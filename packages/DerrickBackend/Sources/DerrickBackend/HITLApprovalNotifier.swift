import DBRepository
import Foundation
import ServiceContracts

/// Pending HITL approval → Daemon UserNotifications (sole poster).
public enum HITLApprovalNotifier: Sendable {
    public static func notifyPending(approvalID: String, repository: DBRepository) async {
        guard let row = try? await repository.fetchPendingHITLApproval(id: approvalID),
              row.status == .pending,
              row.notifyPosted == false
        else { return }
        await postRow(row, repository: repository)
    }

    public static func pollAndPost(repository: DBRepository) async {
        let rows = (try? await repository.fetchPendingHITLApprovalsNeedingNotify()) ?? []
        for row in rows {
            guard shouldNotify(row) else { continue }
            await postRow(row, repository: repository)
        }
    }

    // MARK: - Private

    private static func shouldNotify(_ row: PendingHITLApprovalRow) -> Bool {
        true
    }

    private static func postRow(_ row: PendingHITLApprovalRow, repository: DBRepository) async {
        guard (try? await repository.claimHITLNotificationPost(id: row.id)) == true else { return }

        let isNetwork = isNetworkToolName(row.toolName)
        let host = host(fromNetworkToolName: row.toolName)
        let title = isNetwork ? "Network access needed" : "Approval needed"
        let body: String
        if isNetwork, let host {
            body = "The agent wants to reach \(host). Tap to approve or deny."
        } else {
            let preview = truncated(row.argumentsJSON, limit: 160)
            body = preview.isEmpty
                ? "The agent wants to run “\(row.toolName)”. Tap to approve or deny."
                : "“\(row.toolName)” — \(preview)"
        }

        let request = UserNotificationRequest(
            id: row.id,
            kind: .hitlApproval,
            title: title,
            body: body,
            threadIdentifier: row.id,
            timeSensitive: true,
            userInfo: [
                UserNotificationUserInfoKey.kind.rawValue: UserNotificationKind.hitlApproval.rawValue,
                UserNotificationUserInfoKey.approvalID.rawValue: row.id
            ]
        )

        do {
            try await NotificationSender.post(request)
            fputs("[HITLApprovalNotifier] posted id=\(row.id) tool=\(row.toolName) turn=\(row.turnID)\n", stderr)
            // Banner only — do not auto-present the Allow/Deny sheet while the UI is open.
            // Tap on the banner wakes presentation via DaemonNotificationCenterDelegate.
        } catch {
            try? await repository.resetHITLNotificationClaim(id: row.id)
            fputs(
                "[HITLApprovalNotifier] post failed id=\(row.id): \(error.localizedDescription)\n",
                stderr
            )
        }
    }

    private static func isNetworkToolName(_ toolName: String) -> Bool {
        toolName.hasPrefix("network:")
    }

    private static func host(fromNetworkToolName toolName: String) -> String? {
        guard toolName.hasPrefix("network:") else { return nil }
        let host = String(toolName.dropFirst("network:".count))
        return host.isEmpty ? nil : host
    }

    private static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}
