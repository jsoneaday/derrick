import Foundation

/// Portable Agent Plugins `name` / Derrick `plugin_id`.
public struct PluginID: RawRepresentable, Codable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String

    public var description: String { rawValue }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        try PluginID.validate(trimmed)
        self.rawValue = trimmed
    }

    /// Factory-side cleanup: lowercase, turn `_` and spaces into `-`, then validate.
    /// Published `plugin.json` names still have to match Agent Plugins 1.0.
    public static func normalized(_ raw: String) throws -> PluginID {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var collapsed = ""
        var last: Character?
        for character in lowered {
            let mapped: Character
            if character == "_" || character.isWhitespace {
                mapped = "-"
            } else {
                mapped = character
            }
            if (mapped == "-" && last == "-") || (mapped == "." && last == ".") {
                continue
            }
            collapsed.append(mapped)
            last = mapped
        }
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        do {
            return try PluginID(trimmed)
        } catch {
            throw PluginManifestError.invalidName(raw)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        try PluginID.validate(raw)
        rawValue = raw
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Agent Plugins 1.0 name rules: 1–64 chars, `a-z` `0-9` `-` `.`,
    /// start/end alphanumeric, no `--` or `..`.
    public static func validate(_ raw: String) throws {
        guard (1...64).contains(raw.count) else {
            throw PluginManifestError.invalidName(raw)
        }
        let pattern = #"^(?!.*(?:--|\.\.))[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$"#
        guard raw.range(of: pattern, options: .regularExpression) != nil else {
            throw PluginManifestError.invalidName(raw)
        }
    }
}
