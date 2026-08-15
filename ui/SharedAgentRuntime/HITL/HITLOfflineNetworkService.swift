import DBRepository
import Foundation
import PolicyUserInteraction
import ServiceContracts

/// Network allow/deny via SQLite + user notifications (same path as tool HITL).
public enum HITLOfflineNetworkService {
    private static let pollIntervalNanoseconds: UInt64 = 1_000_000_000

    public static func awaitDecision(
        host: String,
        toolName: String,
        turnID: String,
        isJobContext: Bool,
        repository: DBRepository,
        timeoutNanoseconds: UInt64,
        argumentsJSON: String? = nil
    ) async -> PolicyUserDecision {
        let argumentsJSON = argumentsJSON ?? #"{"host":"\#(host)","toolName":"\#(toolName)"}"#
        let networkTool = networkToolName(host: host)
        let approvalID: String
        if let existing = try? await repository.fetchOpenPendingNetworkApproval(host: host, isJobContext: isJobContext) {
            approvalID = existing.id
            fputs("[HITL] network reusing pending id=\(approvalID) host=\(host) turn=\(turnID) job=\(isJobContext)\n", stderr)
        } else {
            let request = ApprovalConfirmationRequest(
                sessionID: "network-\(host)",
                toolName: networkTool,
                argumentsJSON: argumentsJSON,
                requiredFields: []
            )
            approvalID = request.id
            let row = PendingHITLApprovalRow(
                id: approvalID,
                turnID: turnID,
                sessionID: request.sessionID,
                toolName: request.toolName,
                argumentsJSON: request.argumentsJSON,
                requiredFieldsJSON: "[]",
                isJobContext: isJobContext
            )
            do {
                try await repository.insertPendingHITLApproval(row)
                fputs("[HITL] network queued id=\(approvalID) host=\(host) turn=\(turnID)\n", stderr)
            } catch {
                fputs("[HITL] network persist failed: \(error.localizedDescription)\n", stderr)
                return .denied(actor: "system-persist-failed")
            }
        }

        DerrickHITLNotificationSignal.postPoll()

        let deadline = Date().addingTimeInterval(Double(timeoutNanoseconds) / 1_000_000_000)
        while Date() < deadline {
            if Task.isCancelled {
                try? await repository.resolveHITLApproval(
                    id: approvalID,
                    status: .cancelled,
                    editedArgumentsJSON: nil,
                    actor: "system-cancelled"
                )
                return .denied(actor: "system-cancelled")
            }
            if let decision = try? await repository.fetchPendingHITLApproval(id: approvalID),
               decision.status != .pending {
                return mapDecision(row: decision)
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        try? await repository.resolveHITLApproval(
            id: approvalID,
            status: .timeout,
            editedArgumentsJSON: nil,
            actor: "system-timeout"
        )
        return .timedOut
    }

    public static func networkToolName(host: String) -> String {
        "network:\(host)"
    }

    public static func isNetworkToolName(_ toolName: String) -> Bool {
        toolName.hasPrefix("network:")
    }

    public static func host(fromNetworkToolName toolName: String) -> String? {
        guard toolName.hasPrefix("network:") else { return nil }
        let host = String(toolName.dropFirst("network:".count))
        return host.isEmpty ? nil : host
    }

    private static func mapDecision(row: PendingHITLApprovalRow) -> PolicyUserDecision {
        switch row.status {
        case .approved:
            let actor = row.actor
            if actor?.contains("always") == true {
                return .approvedPermanently(actor: actor)
            }
            return .approvedOnce(actor: actor)
        case .cancelled:
            return .denied(actor: row.actor)
        case .timeout:
            return .timedOut
        case .pending:
            return .denied(actor: "system-pending")
        }
    }
}
