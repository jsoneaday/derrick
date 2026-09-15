import Foundation
import Plugin
import Structure

/// Conservative source checks for standalone Go guest scripts.
public enum GoScriptVerifier: Sendable {
    public static func validate(
        source: String,
        dependencies: [String: String] = [:]
    ) -> [String] {
        var findings = GuestGoSourceValidator.validate(source: source)
        if !dependencies.isEmpty {
            findings.append("Guest script dependencies are not supported.")
        }
        return findings
    }
}
