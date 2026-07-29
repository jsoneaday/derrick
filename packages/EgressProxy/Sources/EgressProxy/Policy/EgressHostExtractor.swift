import Foundation

/// Pulls hostname candidates from script/source text for egress preflight.
public enum EgressHostExtractor: Sendable {
    /// Extracts unique hostnames from common URL shapes in text.
    public static func extractHosts(from text: String) -> [String] {
        var found = Set<String>()

        // https://host, http://host, //host
        let urlPattern = #"https?://([A-Za-z0-9.-]+\.[A-Za-z]{2,})(?::\d+)?"#
        // bare host.tld in quotes often used by requests
        let quotedHostPattern = #"[\"']([A-Za-z0-9.-]+\.[A-Za-z]{2,})[\"']"#

        for pattern in [urlPattern, quotedHostPattern] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(text.startIndex..., in: text)
            regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                guard let match, match.numberOfRanges >= 2,
                      let hostRange = Range(match.range(at: 1), in: text) else { return }
                let host = String(text[hostRange]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard isPlausibleHostname(host) else { return }
                found.insert(host)
            }
        }

        return found.sorted()
    }

    public static func isPlausibleHostname(_ host: String) -> Bool {
        guard !host.isEmpty, host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else {
            return false
        }
        // Skip package-like tokens with no TLD-ish shape
        let labels = host.split(separator: ".")
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2 else { return false }
        return host.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil
    }

    /// Domain suffix to store for permanent allow (registrable-ish: last two labels).
    public static func permanentSuffix(for host: String) -> String {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = normalized.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return normalized }
        // Keep multi-part public suffixes simple: last two labels (reactjs.org, github.com).
        return parts.suffix(2).joined(separator: ".")
    }
}
