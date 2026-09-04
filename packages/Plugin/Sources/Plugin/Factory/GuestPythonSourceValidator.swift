import Foundation

/// Conservative source checks for Python guest plugins and factory drafts.
public enum GuestPythonSourceValidator: Sendable {
    public static func validate(
        source: String,
        dependencies: [String: String] = [:]
    ) -> [String] {
        var findings: [String] = []
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            findings.append("Python source is empty.")
        }

        let forbiddenTokens: [(String, String)] = [
            ("import socket", "Direct socket access is not allowed; emit http.request envelopes."),
            ("from socket", "Direct socket access is not allowed; emit http.request envelopes."),
            ("import urllib", "Direct network access is not allowed; emit http.request envelopes."),
            ("from urllib", "Direct network access is not allowed; emit http.request envelopes."),
            ("import requests", "Direct network access is not allowed; emit http.request envelopes."),
            ("import httpx", "Direct network access is not allowed; emit http.request envelopes."),
            ("import subprocess", "Process execution is not allowed."),
            ("os.system(", "Process execution is not allowed."),
            ("os.popen(", "Process execution is not allowed."),
            ("open(", "Filesystem access is not allowed in guest plugins."),
        ]
        for (token, message) in forbiddenTokens where source.contains(token) {
            findings.append(message)
        }

        let readsStdin = source.contains("sys.stdin")
            || source.contains("input(")
            || source.contains("stdin.read")
        if !readsStdin {
            findings.append("Python source must read its JSON event from standard input.")
        }
        if !dependencies.isEmpty {
            findings.append("Guest plugin dependencies are not supported; use the standard library.")
        }
        return findings
    }
}
