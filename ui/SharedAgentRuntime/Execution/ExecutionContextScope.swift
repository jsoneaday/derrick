import AgentRuntime
import Foundation
import ServiceContracts

/// Installs per-agent execution contexts for worker turns (forked from the parent user-facing turn).
public enum ExecutionContextScope {
    public static func runWorkerTurn<T: Sendable>(
        agentRef: AgentRef,
        operation: () async throws -> T
    ) async rethrows -> T {
        let childID = ExecutionContextID(agentRef: agentRef)
        let parentID = TurnProcessContext.executionContextID
            ?? ExecutionContextID(sessionID: agentRef.sessionID, agentID: AgentRef.userFacingAgentID)

        ExecutionContextRegistry.shared.installDerived(childID, from: parentID)
        defer { ExecutionContextRegistry.shared.removeDerived(childID) }

        return try await TurnProcessContext.$executionContextID.withValue(childID) {
            try await AgentCallContext.$caller.withValue(agentRef) {
                try await operation()
            }
        }
    }
}
