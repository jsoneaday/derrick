import Foundation

/// Named Docker volumes Derrick may create. `volume rm` is allowed only for removable kinds.
public enum DerrickNamedVolume: Sendable {
    public static let helpers = "derrick-script-helpers"

    public static let removableKinds = ["plugin-code", "plugin-data", "plugin-staging", "script-scratch"]

    /// `^derrick-(plugin-code|plugin-data|plugin-staging|script-scratch)-[a-z0-9-]+$`
    public static func isRemovable(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != helpers else { return false }
        let kinds = removableKinds.joined(separator: "|")
        return name.range(of: "^derrick-(\(kinds))-[a-z0-9-]+$", options: .regularExpression) != nil
    }

    public static func scriptScratch(suffix: String) -> String {
        "derrick-script-scratch-\(sanitized(suffix))"
    }

    public static func pluginCode(id: String, hash8: String) -> String {
        "derrick-plugin-code-\(sanitized(id))-\(sanitized(hash8))"
    }

    public static func pluginData(id: String) -> String {
        "derrick-plugin-data-\(sanitized(id))"
    }

    public static func pluginStaging(factoryID: String) -> String {
        "derrick-plugin-staging-\(sanitized(factoryID))"
    }

    public static func volumeIOContainer(suffix: String) -> String {
        "derrick-volio-\(sanitized(suffix))"
    }

    private static func sanitized(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let mapped = lowered.map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "-" { return ch }
            return "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "x" : collapsed
    }
}
