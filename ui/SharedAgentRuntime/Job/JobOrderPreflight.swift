import EgressProxy
import Foundation

/// Helpers for inspecting job tool arguments (network hosts, script flags).
public enum JobOrderPreflight {
    public static func scriptAllowNetwork(toolArgumentsJSON: String) -> Bool {
        guard let data = toolArgumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if let allow = object["allow_network"] as? Bool { return allow }
        if let allow = object["allow_network"] as? Int { return allow != 0 }
        if let allow = object["allow_network"] as? String {
            let lowered = allow.lowercased()
            return lowered == "true" || lowered == "1"
        }
        return false
    }

    public static func scriptSource(from toolArgumentsJSON: String) -> String {
        guard let data = toolArgumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let script = object["script"] as? String else {
            return ""
        }
        return script
    }

    public static func extractNetworkHosts(script: String) -> [String] {
        EgressHostExtractor.extractHosts(from: script)
    }
}
