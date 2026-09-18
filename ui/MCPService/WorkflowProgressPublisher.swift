import Foundation
import Structure

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

    /// Maps `[plugin_factory]` log lines to workflow stages for the create UI.
    static func factoryStage(from logLine: String) -> String {
        let line = logLine.lowercased()
        if line.contains("review_started")
            || line.contains("review_streaming")
            || line.contains("review decision")
            || line.contains("review rejected") {
            return "review"
        }
        if line.contains("package_started")
            || line.contains("packaged_test") {
            return "package"
        }
        if line.contains("direct_test")
            || line.contains("draft_ready") {
            return "trial"
        }
        if line.contains("draft_started")
            || line.contains("builder_streaming") {
            return "builder"
        }
        return "builder"
    }
}
