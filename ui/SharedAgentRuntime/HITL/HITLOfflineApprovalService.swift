import DBRepository
import Foundation
import Structure

/// Queue + wait for human approval when the UI XPC sink is unavailable.
public enum HITLOfflineApprovalService {
    private static let pollIntervalNanoseconds: UInt64 = 1_000_000_000

    public static func awaitDecision(
        request: ApprovalConfirmationRequest,
        turnID: String,
        isJobContext: Bool,
        repository: DBRepository,
        timeoutNanoseconds: UInt64
    ) async -> ApprovalConfirmationDecision {
        let requiredJSON = (try? JSONEncoder().encode(request.requiredFields))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let row = PendingHITLApprovalRow(
            id: request.id,
            turnID: turnID,
            sessionID: request.sessionID,
            toolName: request.toolName,
            argumentsJSON: request.argumentsJSON,
            requiredFieldsJSON: requiredJSON,
            isJobContext: isJobContext
        )
        do {
            try await repository.insertPendingHITLApproval(row)
        } catch {
            fputs("[HITL] persist failed: \(error.localizedDescription)\n", stderr)
            return .cancelled(actor: "system-persist-failed")
        }

        DerrickHITLNotificationSignal.postPoll()

        let deadline = Date().addingTimeInterval(Double(timeoutNanoseconds) / 1_000_000_000)
        while Date() < deadline {
            if Task.isCancelled {
                try? await repository.resolveHITLApproval(
                    id: request.id,
                    status: .cancelled,
                    editedArgumentsJSON: nil,
                    actor: "system-cancelled"
                )
                return .cancelled(actor: "system-cancelled")
            }
            if let decision = try? await repository.fetchPendingHITLApproval(id: request.id),
               decision.status != .pending {
                return mapDecision(row: decision, fallbackArgs: request.argumentsJSON)
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        try? await repository.resolveHITLApproval(
            id: request.id,
            status: .timeout,
            editedArgumentsJSON: nil,
            actor: "system-timeout"
        )
        fputs("[HITL] approval timed out id=\(request.id) tool=\(request.toolName)\n", stderr)
        return .cancelled(actor: "system-timeout")
    }

    private static func mapDecision(
        row: PendingHITLApprovalRow,
        fallbackArgs: String
    ) -> ApprovalConfirmationDecision {
        switch row.status {
        case .approved:
            let args = row.editedArgumentsJSON?.isEmpty == false
                ? row.editedArgumentsJSON!
                : fallbackArgs
            return .approved(editedArgumentsJSON: args, actor: row.actor)
        case .cancelled, .timeout, .pending:
            return .cancelled(actor: row.actor ?? row.status.rawValue)
        }
    }
}
