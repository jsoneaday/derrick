import Foundation

/// MCP effector admission under Guardrail. Policy vocabulary: allow or deny.
///
/// Effectors are MCP-hosted side-effect tools (`web.crawl`, `script_exec`, …).
/// Admission belongs to Guardrail/Policy, not to plugins.
public enum EffectorAdmissionPolicy: Sendable {
    public static func syncWebCrawlDecision(
        context: ExecutionContextWire?,
        principal: ServicePrincipal
    ) -> GuardrailDecision {
        if allowsSyncWebCrawl(context: context, principal: principal) {
            return .allow
        }
        return .deny(reason: "Sync web crawl is not admitted for this execution context.")
    }

    public static func allowsSyncWebCrawl(
        context: ExecutionContextWire?,
        principal: ServicePrincipal
    ) -> Bool {
        switch principal {
        case .job, .agent:
            return true
        default:
            break
        }
        if let context, context.capabilities.contains(.syncWebCrawl) { return true }
        if let context, context.workflow?.kind == .pluginFactoryCreate { return true }
        return false
    }

    public static func parseContextJSON(_ json: String?) -> ExecutionContextWire? {
        guard let json,
              !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return try? ExecutionContextWire.decodeJSON(json)
    }
}
