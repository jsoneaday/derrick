import Foundation

/// Conservative source checks for standalone Swift scripts.
public enum SwiftScriptVerifier: Sendable {
    public static func validate(
        source: String,
        dependencies: [String: String] = [:]
    ) -> [String] {
        var findings: [String] = []
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            findings.append("Swift source is empty.")
        }
        if source.contains("import Glibc") || source.contains("import Darwin") {
            findings.append("Direct system and socket APIs are not allowed.")
        }

        let forbiddenTokens: [(String, String)] = [
            ("Process(", "Process execution is not allowed."),
            ("URLSession", "Direct network access is not allowed; emit http.request envelopes."),
            ("NWConnection", "Direct network access is not allowed; emit http.request envelopes."),
            ("Socket", "Direct socket access is not allowed."),
            ("FoundationNetworking", "Direct network access is not allowed; emit http.request envelopes."),
            ("FileManager.default", "Filesystem access is not allowed in script_exec."),
            ("FileHandle.standardError", "Write only the JSON envelope array to standard output."),
        ]
        for (token, message) in forbiddenTokens where source.contains(token) {
            findings.append(message)
        }

        if source.contains("import PackageDescription") {
            findings.append("Swift package manifests are not allowed in script_exec.")
        }
        if !source.contains("FileHandle.standardInput")
            && !source.contains("readLine(")
            && !source.contains("readDataToEndOfFile") {
            findings.append("Swift source must read its JSON event from standard input.")
        }
        if dependencies.isEmpty == false {
            findings.append("Swift script dependencies are not supported; use the standard library and Foundation.")
        }
        return findings
    }
}
