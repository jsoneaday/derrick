import Foundation
import Structure

public enum GuestGoSourceValidator: Sendable {
    private static let forbiddenImports = [
        "\"net/http\"",
        "\"net\"",
        "\"os/exec\"",
        "\"crypto/tls\"",
    ]

    private static let forbiddenCalls = [
        "os.Open",
        "os.ReadFile",
        "os.WriteFile",
        "exec.Command",
        "http.Get",
        "http.Post",
        "http.Client",
    ]

    public static func validate(source: String) -> [String] {
        var findings: [String] = []
        for token in forbiddenImports where source.contains(token) {
            findings.append("Go guest must not import \(token).")
        }
        for token in forbiddenCalls where source.contains(token) {
            findings.append("Go guest must not call \(token).")
        }
        if !source.contains("package main") {
            findings.append("Go guest source must declare package main.")
        }
        return findings
    }
}
