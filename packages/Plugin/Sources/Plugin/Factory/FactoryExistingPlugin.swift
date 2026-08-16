import Foundation

/// When the user is changing an installed plugin, keep that `plugin_id` and bump the version.
public enum FactoryExistingPlugin: Sendable {
    public enum Decision: Equatable, Sendable {
        case create
        case reuse(String)
        /// More than one installed plugin fits what they said. Ask which one.
        case ambiguous([String])
    }

    /// Installed id the goal is clearly changing, or `nil` for a new plugin.
    public static func match(goal: String, installedIDs: [String]) -> String? {
        if case .reuse(let id) = decide(goal: goal, installedIDs: installedIDs) {
            return id
        }
        return nil
    }

    public static func decide(goal: String, installedIDs: [String]) -> Decision {
        let ids = uniqueIDs(installedIDs)
        guard !ids.isEmpty else { return .create }
        let scored = ids.map { ($0, nameScore(pluginID: $0, goal: goal)) }.filter { $0.1 > 0 }
        let best = scored.map(\.1).max() ?? 0
        let winners = scored.filter { $0.1 == best }.map(\.0)
        if winners.count == 1, let only = winners.first {
            return isEditIntent(goal) ? .reuse(only) : .create
        }
        if winners.count > 1 {
            return isEditIntent(goal) ? .ambiguous(winners) : .create
        }
        guard isEditIntent(goal) else { return .create }
        if ids.count == 1, let only = ids.first {
            return .reuse(only)
        }
        return .ambiguous(ids)
    }

    public static func isEditIntent(_ goal: String) -> Bool {
        let text = goal.lowercased()
        let markers = [
            "edit", "update", "change", "modify", "existing", "upgrade",
            "add param", "add a param", "so that it can", "fix the",
        ]
        return markers.contains { text.contains($0) }
    }

    /// People type "daily news", not `daily-news`. Match tokens and prefixes, not exact ids.
    public static func nameFits(pluginID: String, goal: String) -> Bool {
        nameScore(pluginID: pluginID, goal: goal) > 0
    }

    /// How many words of the plugin name appear in the request. Higher is more specific.
    public static func nameScore(pluginID: String, goal: String) -> Int {
        let goalTokens = contentTokens(goal)
        guard !goalTokens.isEmpty else { return 0 }
        return tokens(pluginID).filter { idToken in
            goalTokens.contains { tokensMatch($0, idToken) }
        }.count
    }
}

/// Semver-ish `major.minor.patch` used as `plugin_versions.version`.
public enum PluginReleaseVersion: Sendable {
    public static func next(after raw: String) -> String {
        let parts = parse(raw)
        return render(major: parts.0, minor: parts.1, patch: parts.2 + 1)
    }

    /// Keep a requested version if it is unused and newer; otherwise bump the latest.
    public static func assign(requested: String, existing: [String]) -> String {
        let used = existing.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let wanted = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        if used.isEmpty {
            return wanted.isEmpty ? "1.0.0" : wanted
        }
        if !wanted.isEmpty, !used.contains(wanted), compare(wanted, used) > 0 {
            return wanted
        }
        let latest = used.max { compareParts(parse($0), parse($1)) < 0 } ?? "1.0.0"
        var candidate = next(after: latest)
        var seen = Set(used)
        while seen.contains(candidate) {
            seen.insert(candidate)
            candidate = next(after: candidate)
        }
        return candidate
    }

    public static func compare(_ lhs: String, _ existing: [String]) -> Int {
        let right = existing.map(parse)
        guard let maxRight = right.max(by: { compareParts($0, $1) < 0 }) else { return 1 }
        return compareParts(parse(lhs), maxRight)
    }

    private static func parse(_ raw: String) -> (Int, Int, Int) {
        let pieces = raw.split(separator: ".").prefix(3).compactMap { Int($0) }
        return (
            pieces.count > 0 ? pieces[0] : 0,
            pieces.count > 1 ? pieces[1] : 0,
            pieces.count > 2 ? pieces[2] : 0
        )
    }

    private static func render(major: Int, minor: Int, patch: Int) -> String {
        "\(major).\(minor).\(patch)"
    }

    private static func compareParts(_ lhs: (Int, Int, Int), _ rhs: (Int, Int, Int)) -> Int {
        if lhs.0 != rhs.0 { return lhs.0 < rhs.0 ? -1 : 1 }
        if lhs.1 != rhs.1 { return lhs.1 < rhs.1 ? -1 : 1 }
        if lhs.2 != rhs.2 { return lhs.2 < rhs.2 ? -1 : 1 }
        return 0
    }
}

private let ignoredGoalWords: Set<String> = [
    "a", "an", "the", "to", "for", "of", "and", "or", "with", "that", "this", "it", "its",
    "my", "our", "so", "can", "please", "now", "lets", "let's", "plugin", "plugins",
    "existing", "installed", "one", "ones", "edit", "update", "change", "modify", "upgrade",
    "add", "adding", "accept", "accepts", "receive", "allow", "make", "want", "needs",
    "need", "take", "takes", "param", "params", "parameter", "parameters",
]

private func uniqueIDs(_ installedIDs: [String]) -> [String] {
    var seen = Set<String>()
    var ids: [String] = []
    for raw in installedIDs {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty, seen.insert(id).inserted else { continue }
        ids.append(id)
    }
    return ids
}

private func tokens(_ raw: String) -> [String] {
    raw.lowercased()
        .replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .map(String.init)
        .filter { !$0.isEmpty }
}

private func contentTokens(_ goal: String) -> [String] {
    tokens(goal).filter { !ignoredGoalWords.contains($0) }
}

private func tokensMatch(_ goalToken: String, _ pluginToken: String) -> Bool {
    if goalToken == pluginToken { return true }
    if goalToken.count >= 3 && pluginToken.hasPrefix(goalToken) { return true }
    if pluginToken.count >= 3 && goalToken.hasPrefix(pluginToken) { return true }
    return false
}
