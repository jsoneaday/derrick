import DBRepository
import Foundation
import ServiceContracts

/// Waits for human approval via SQLite + user notifications (single path for all turns).
public final class XPCRemoteApprovalPresenter: ApprovalConfirmationPresenting, @unchecked Sendable {
    public typealias RepositoryResolver = @Sendable () async throws -> DBRepository?

    private let turnID: String
    private let resolveRepository: RepositoryResolver
    private let timeoutNanoseconds: UInt64

    public init(
        turnID: String,
        timeoutSeconds: UInt64 = 300,
        resolveRepository: @escaping RepositoryResolver
    ) {
        self.turnID = turnID
        self.timeoutNanoseconds = timeoutSeconds * 1_000_000_000
        self.resolveRepository = resolveRepository
    }

    public func confirm(_ request: ApprovalConfirmationRequest) async -> ApprovalConfirmationDecision {
        guard let repository = try? await resolveRepository() else {
            return .cancelled(actor: "system-no-repository")
        }
        debugLog("HITL: queue notification approval tool=\(request.toolName) id=\(request.id)")
        return await HITLOfflineApprovalService.awaitDecision(
            request: request,
            turnID: turnID,
            isJobContext: JobSessionID.isJobSession(request.sessionID),
            repository: repository,
            timeoutNanoseconds: timeoutNanoseconds
        )
    }
}
