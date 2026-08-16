import Foundation
import ServiceContracts

/// Guest TypeScript SDK and check files loaded from SharedAgentRuntime Resources.
public enum DerrickGuestTypeScript {
    public static var verbUnion: String {
        PluginEnvelopeSchema.verbCases.map { "\"\($0)\"" }.joined(separator: " | ")
    }

    public static var derrickModule: String {
        registerPluginResourceBundle()
        return DerrickBundledText.mustLoad("guest/derrick.ts")
    }

    public static var runnerSource: String {
        registerPluginResourceBundle()
        return DerrickBundledText.mustLoad("guest/runner.ts")
    }

    public static var tsconfigJSON: String {
        registerPluginResourceBundle()
        return DerrickBundledText.mustLoad("guest/tsconfig.json")
    }

    public static var handleCheckTS: String {
        registerPluginResourceBundle()
        return DerrickBundledText.mustLoad("guest/handle-check.ts")
    }

    static func registerPluginResourceBundle() {
        DerrickBundledText.registerSearchRoot(Bundle.module.resourceURL ?? Bundle.module.bundleURL)
    }
}

extension PluginEnvelopeSchema {
    /// Verb enums parsed from `jsonSchema` so generated TS cannot drift.
    public static var verbCases: [String] {
        guard let enumRange = jsonSchema.range(of: "\"enum\"") else { return [] }
        let after = jsonSchema[enumRange.upperBound...]
        guard let start = after.firstIndex(of: "["), let end = after.firstIndex(of: "]") else {
            return []
        }
        let body = after[after.index(after: start)..<end]
        return body.split(separator: ",").compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else { return nil }
            return String(trimmed.dropFirst().dropLast())
        }
    }

    /// Model-facing handle contract. Full SDK is `DerrickGuestTypeScript.derrickModule`.
    public static var ragSection: String {
        DerrickGuestTypeScript.registerPluginResourceBundle()
        return DerrickBundledText.mustLoad("plugin_handle_instructions.md")
    }
}
