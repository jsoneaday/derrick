import EgressProxy
import Foundation
import ServiceContracts

/// Determines what human approval is needed before placing a job order (live chat scheduling).
public enum JobOrderPreflight {
    public static func buildRequest(
        toolName: String,
        toolArgumentsJSON: String,
        uncoveredNetworkHosts: [String]
    ) -> JobPreflightRequestDTO? {
        guard !uncoveredNetworkHosts.isEmpty else { return nil }

        var items: [JobPreflightItemDTO] = []

        if toolName == "python_script_exec" {
            let preview = scriptPreview(from: toolArgumentsJSON)
            let networkNote = "\n\nNetwork: \(uncoveredNetworkHosts.joined(separator: ", "))"
            items.append(
                JobPreflightItemDTO(
                    kind: "tool",
                    title: "Run scheduled Python script",
                    detail: preview + networkNote
                )
            )
        } else {
            items.append(
                JobPreflightItemDTO(
                    kind: "tool",
                    title: "Run scheduled tool “\(toolName)”",
                    detail: truncated(toolArgumentsJSON, limit: 400)
                )
            )
        }

        for host in uncoveredNetworkHosts {
            items.append(
                JobPreflightItemDTO(
                    kind: "network",
                    title: "Network access",
                    detail: "Allow the job to reach \(host)"
                )
            )
        }

        guard !items.isEmpty else { return nil }
        return JobPreflightRequestDTO(toolName: toolName, items: items)
    }

    public static func pythonAllowNetwork(toolArgumentsJSON: String) -> Bool {
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

    public static func pythonScript(from toolArgumentsJSON: String) -> String {
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

    private static func scriptPreview(from toolArgumentsJSON: String) -> String {
        let script = pythonScript(from: toolArgumentsJSON)
        guard !script.isEmpty else {
            return truncated(toolArgumentsJSON, limit: 320)
        }
        return truncated(script, limit: 320)
    }

    private static func truncated(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}
