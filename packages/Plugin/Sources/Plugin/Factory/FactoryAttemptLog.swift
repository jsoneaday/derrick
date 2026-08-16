import Foundation

/// Compact factory attempt text for the debug log and `FactoryPackageDraft.attemptLog`.
public enum FactoryAttemptLog: Sendable {
    public static func describe(
        tool: String,
        arguments: [String: String] = [:],
        result: String?
    ) -> String {
        let payload = decode(result)
        var lines: [String] = [
            "[factory] \(tool) ok=\(payload.ok.map { $0 ? "true" : "false" } ?? "?") stage=\(payload.stage ?? "-") plugin=\(arguments["plugin_id"] ?? payload.pluginID ?? "-")",
        ]
        if let error = payload.error, !error.isEmpty {
            lines.append("[factory] error: \(error)")
        }
        if !payload.findings.isEmpty {
            lines.append("[factory] findings: \(payload.findings.joined(separator: " | "))")
        }
        if let summary = payload.summary, !summary.isEmpty {
            lines.append("[factory] summary: \(summary)")
        }
        if let stdout = payload.stdout, !stdout.isEmpty {
            lines.append("[factory] stdout: \(stdout)")
        }
        if !payload.concerns.isEmpty {
            lines.append("[factory] concerns: \(payload.concerns.joined(separator: " | "))")
        }
        if let next = payload.next, !next.isEmpty {
            lines.append("[factory] next: \(next)")
        }
        if let handle = arguments["handle"], !handle.isEmpty {
            lines.append("[factory] handle_chars=\(handle.count)")
            lines.append("[factory] handle begin")
            lines.append(handle)
            lines.append("[factory] handle end")
        }
        return lines.joined(separator: "\n")
    }

    private struct Payload {
        var ok: Bool?
        var stage: String?
        var error: String?
        var summary: String?
        var stdout: String?
        var next: String?
        var pluginID: String?
        var findings: [String] = []
        var concerns: [String] = []
    }

    private static func decode(_ raw: String?) -> Payload {
        guard let raw, let brace = raw.firstIndex(of: "{"),
              let data = String(raw[brace...]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            var payload = Payload()
            if let raw, !raw.isEmpty { payload.error = String(raw.prefix(400)) }
            return payload
        }
        var payload = Payload()
        payload.ok = object["ok"] as? Bool
        payload.stage = object["stage"] as? String
        payload.error = object["error"] as? String
        payload.summary = object["summary"] as? String
        payload.stdout = object["stdout"] as? String
        payload.next = object["next"] as? String
        payload.pluginID = object["plugin_id"] as? String ?? object["reuse_plugin_id"] as? String
        payload.findings = object["static_findings"] as? [String] ?? []
        payload.concerns = object["concerns"] as? [String] ?? []
        return payload
    }
}
