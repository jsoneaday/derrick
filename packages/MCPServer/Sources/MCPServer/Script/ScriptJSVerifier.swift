import Foundation

public enum ScriptJSVerifier: Sendable {
    public static func validate(script: String, dependencies: [String: String]) -> [String] {
        var findings: [String] = []
        let text = script
        let banned: [(String, String)] = [
            (#"\bfetch\s*\("#, "Guest fetch() is banned; return netFetch(...) from handle()."),
            (#"node:http"#, "Direct HTTP modules are banned."),
            (#"node:https"#, "Direct HTTP modules are banned."),
            (#"node:net"#, "Direct sockets are banned."),
            (#"node:child_process"#, "child_process is banned."),
            (#"Bun\.connect"#, "Bun.connect is banned."),
            (#"Bun\.serve"#, "Bun.serve is banned."),
            (#"host\.docker\.internal"#, "host.docker.internal is blocked."),
            (#"169\.254\.169\.254"#, "Link-local metadata addresses are blocked."),
        ]
        for (pattern, message) in banned {
            if text.range(of: pattern, options: .regularExpression) != nil {
                findings.append(message)
            }
        }
        if !text.contains("export function handle") && !text.contains("export async function handle") {
            findings.append("Script must export function handle.")
        }
        for name in dependencies.keys {
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                findings.append("Empty dependency name.")
            }
        }
        return findings
    }
}
