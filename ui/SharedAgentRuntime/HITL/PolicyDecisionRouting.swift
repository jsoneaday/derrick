import AppEvents
import Foundation
import PolicyUserInteraction
import ServiceContracts

/// Routes policy decision prompts to the correct process.
/// AgentService has no PolicyEventPresenter — never call local `AppEventBus.initDecision` there
/// or the turn hangs forever with no modal.
enum PolicyDecisionRouting {
    private static var isAgentServiceProcess: Bool {
        let bid = Bundle.main.bundleIdentifier ?? ""
        return bid == DerrickServiceID.agent.rawValue || bid.hasSuffix(".AgentService")
    }

    static func requestDecision(_ event: PolicyUserEvent) async -> PolicyUserDecision {
        if let remote = TurnProcessContext.effectivePolicyDecisionPrompt {
            return await remote(event)
        }
        if isAgentServiceProcess {
            fputs(
                "[AgentRuntime] policy decision fail-closed (no UI prompt) kind=\(event.kind.rawValue) title=\(event.title)\n",
                stderr
            )
            return .denied(actor: "system-no-policy-prompt")
        }
        return await AppEventBus.shared.initDecision(event)
    }

    static func publishNotice(_ event: PolicyUserEvent) async {
        if isAgentServiceProcess {
            fputs(
                "[AgentRuntime] policy notice kind=\(event.kind.rawValue) title=\(event.title) summary=\(event.summary)\n",
                stderr
            )
            return
        }
        await AppEventBus.shared.publish(event)
    }
}
