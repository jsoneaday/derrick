import Foundation
import ServiceContracts

/// Publishes in-flight tool progress into `workflow_run_events` for host workflows.
enum WorkflowProgressPublisher {
    static func publish(stage: String, message: String) async {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let workflowID = MCPServiceCallContext.shared.workflowID
        else {
            return
        }
        do {
            let repo = try await MCPServiceStore.shared.sharedRepository()
            _ = try await repo.appendWorkflowEvent(
                workflowID: workflowID,
                kind: "progress",
                stage: stage,
                message: trimmed
            )
        } catch {
            fputs("[MCPService] workflow progress publish failed: \(error.localizedDescription)\n", stderr)
        }
    }

    static func userFacingFactoryProgress(from logLine: String) -> String? {
        WorkflowChatProgress.factoryProgressMessage(from: logLine)
    }
}
