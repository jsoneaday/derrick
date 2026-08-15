import Foundation

/// `/plugin-id rest` chat prefix. Skip the LLM when exactly one installed plugin matches.
public enum PluginPrefix: Sendable {
    public struct Parsed: Sendable, Equatable {
        public var handle: String
        public var remainder: String

        public init(handle: String, remainder: String) {
            self.handle = handle
            self.remainder = remainder
        }
    }

    public static func parse(_ prompt: String) -> Parsed? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = String(trimmed.dropFirst())
        guard !body.hasPrefix("/") else { return nil }
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return nil }
        let handle = String(first).lowercased()
        guard handle.range(of: #"^[a-z0-9](?:[a-z0-9.-]{0,62}[a-z0-9])?$"#, options: .regularExpression) != nil else {
            return nil
        }
        let remainder = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return Parsed(handle: handle, remainder: remainder)
    }

    /// Unique match: exact id, or a single prefix of an installed id.
    public static func uniqueMatch(handle: String, pluginIDs: [String]) -> String? {
        let needle = handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        let ids = pluginIDs.map { $0.lowercased() }
        if ids.contains(needle) { return needle }
        let prefixed = ids.filter { $0.hasPrefix(needle) }
        return prefixed.count == 1 ? prefixed[0] : nil
    }

    /// Handle currently being typed after `/`. `""` means `/` alone (show every plugin).
    /// `nil` means this is not a slash-handle edit (plain text, `//`, or a space after the id).
    public static func typingHandle(_ prompt: String) -> String? {
        guard prompt.hasPrefix("/") else { return nil }
        let rest = prompt.dropFirst()
        guard !rest.hasPrefix("/") else { return nil }
        if rest.contains(where: { $0.isNewline || $0 == " " }) { return nil }
        let handle = String(rest).lowercased()
        if handle.isEmpty { return "" }
        guard handle.range(of: #"^[a-z0-9][a-z0-9.-]*$"#, options: .regularExpression) != nil else {
            return nil
        }
        return handle
    }

    /// Prefix matches first, then ids that contain the needle. Empty needle lists all ids.
    public static func matches(handle: String, pluginIDs: [String]) -> [String] {
        let needle = handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ids = pluginIDs.map { $0.lowercased() }
        if needle.isEmpty { return ids.sorted() }
        let prefixHits = ids.filter { $0.hasPrefix(needle) }.sorted()
        let containsHits = ids.filter { !$0.hasPrefix(needle) && $0.contains(needle) }.sorted()
        return prefixHits + containsHits
    }
}
