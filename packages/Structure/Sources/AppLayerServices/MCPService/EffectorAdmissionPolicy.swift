import Foundation

/// MCP effector admission from signed `ExecutionContextWire` (not process-local flags).
public enum EffectorAdmissionPolicy: Sendable {
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
