import DBRepository
import Foundation
import PolicyUserInteraction
import Structure

/// Network host allow via SQLite + user notifications.
public enum XPCRemoteNetworkAccess {
    public static func prompt(
        host: String,
        toolName: String,
        turnID: String,
        isJobContext: Bool,
        resolveRepository: @Sendable () async throws -> DBRepository?,
        timeoutSeconds: UInt64 = 300
    ) async -> PolicyUserDecision {
        guard let repository = try? await resolveRepository() else {
            return .denied(actor: "system-no-repository")
        }
        debugLog("HITL network: queue notification host=\(host) tool=\(toolName) turn=\(turnID) job=\(isJobContext)")
        return await HITLOfflineNetworkService.awaitDecision(
            host: host,
            toolName: toolName,
            turnID: turnID,
            isJobContext: isJobContext,
            repository: repository,
            timeoutNanoseconds: timeoutSeconds * 1_000_000_000
        )
    }
}
