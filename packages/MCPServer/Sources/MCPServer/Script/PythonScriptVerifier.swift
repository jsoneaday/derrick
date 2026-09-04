import Foundation
import Plugin

/// Conservative source checks for standalone Python guest scripts.
public enum PythonScriptVerifier: Sendable {
    public static func validate(
        source: String,
        dependencies: [String: String] = [:]
    ) -> [String] {
        GuestPythonSourceValidator.validate(source: source, dependencies: dependencies)
    }
}
