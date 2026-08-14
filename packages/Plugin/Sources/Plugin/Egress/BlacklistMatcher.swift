import Foundation

public enum BlacklistEntryKind: String, Codable, Sendable, Hashable {
    case exact
    case suffix
}

/// Soft-blacklist row: exact host or `*.domain` (subdomains only, not apex).
public struct BlacklistEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: BlacklistEntryKind
    public var pattern: String

    public init(id: String = UUID().uuidString, kind: BlacklistEntryKind, pattern: String) {
        self.id = id
        self.kind = kind
        self.pattern = BlacklistMatcher.normalize(pattern)
    }

    /// Parses `api.example.com` or `*.example.com`.
    public static func parse(_ raw: String) throws -> BlacklistEntry {
        let trimmed = BlacklistMatcher.normalize(raw)
        if trimmed.hasPrefix("*.") {
            let suffix = String(trimmed.dropFirst(2))
            try BlacklistMatcher.validateSuffix(suffix)
            return BlacklistEntry(kind: .suffix, pattern: suffix)
        }
        try BlacklistMatcher.validateExact(trimmed)
        return BlacklistEntry(kind: .exact, pattern: trimmed)
    }

    public var displayPattern: String {
        switch kind {
        case .exact: return pattern
        case .suffix: return "*.\(pattern)"
        }
    }
}

public enum BlacklistMatch: Sendable, Hashable {
    case none
    case hit(BlacklistEntry)
}

public enum BlacklistMatcher {
    /// Multi-label public suffixes we refuse as a wildcard (would blackhole too much).
    public static let rejectedWildcardSuffixes: Set<String> = [
        "com", "org", "net", "edu", "gov", "io", "co", "us", "uk", "de", "fr", "jp",
        "co.uk", "com.au", "co.jp", "com.br", "co.nz",
    ]

    public static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func validateExact(_ host: String) throws {
        let host = normalize(host)
        guard !host.isEmpty, host != "*" else {
            throw BlacklistValidationError.invalidPattern(host)
        }
        if host.hasPrefix("*.") {
            throw BlacklistValidationError.invalidPattern(host)
        }
        guard isPlausibleHost(host) else {
            throw BlacklistValidationError.invalidPattern(host)
        }
    }

    public static func validateSuffix(_ suffix: String) throws {
        let suffix = normalize(suffix)
        guard !suffix.isEmpty, suffix != "*" else {
            throw BlacklistValidationError.rejectedPublicSuffix(suffix)
        }
        if rejectedWildcardSuffixes.contains(suffix) {
            throw BlacklistValidationError.rejectedPublicSuffix(suffix)
        }
        guard isPlausibleHost(suffix) else {
            throw BlacklistValidationError.invalidPattern(suffix)
        }
        // Single-label suffix that is not already in the public-suffix set (e.g. `*.xyz`).
        if !suffix.contains(".") {
            throw BlacklistValidationError.rejectedPublicSuffix(suffix)
        }
    }

    public static func match(host: String, entries: [BlacklistEntry]) -> BlacklistMatch {
        let host = normalize(host)
        guard !host.isEmpty else { return .none }

        var best: BlacklistEntry?
        var bestScore = -1
        for entry in entries {
            switch entry.kind {
            case .exact:
                if host == entry.pattern, 1_000 + entry.pattern.count > bestScore {
                    best = entry
                    bestScore = 1_000 + entry.pattern.count
                }
            case .suffix:
                // Subdomains only — not the apex.
                if host.hasSuffix("." + entry.pattern), host != entry.pattern,
                   100 + entry.pattern.count > bestScore {
                    best = entry
                    bestScore = 100 + entry.pattern.count
                }
            }
        }
        if let best { return .hit(best) }
        return .none
    }

    private static func isPlausibleHost(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count >= 1, !labels.contains(where: { $0.isEmpty }) else { return false }
        return labels.allSatisfy { label in
            label.range(of: #"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$"#, options: .regularExpression) != nil
        }
    }
}

public enum BlacklistValidationError: Error, Equatable, LocalizedError {
    case invalidPattern(String)
    case rejectedPublicSuffix(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPattern(let p):
            return "Invalid blacklist pattern: \(p)"
        case .rejectedPublicSuffix(let p):
            return "Wildcard on a public suffix is not allowed: \(p)"
        }
    }
}
