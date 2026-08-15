import Foundation

/// Pulls hostname candidates from script/source text for egress preflight.
///
/// Only real network destinations should surface. Strings like BeautifulSoup's
/// `'html.parser'` must never be treated as hosts.
public enum EgressHostExtractor: Sendable {
    /// Last labels that look like `host.tld` but are not public DNS TLDs / not network hosts.
    private static let nonHostFinalLabels: Set<String> = [
        "parser", "json", "text", "html", "xml", "xhtml", "py", "pyc", "so",
        "dll", "cfg", "conf", "ini", "yml", "yaml", "toml", "md", "csv",
        "log", "tmp", "cache", "local", "internal", "test", "example",
        "localhost", "localdomain"
    ]

    /// Full hostnames that appear in code but are not network destinations.
    private static let nonHostNames: Set<String> = [
        "html.parser",
        "html5lib",
        "lxml.etree",
        "lxml.html",
        "xml.etree",
        "xml.dom",
        "xml.sax",
        "json.decoder",
        "json.encoder",
        "urllib.parse",
        "urllib.request",
        "http.client",
        "http.server",
        "email.parser",
        "configparser"
    ]

    /// Extracts unique hostnames from URL shapes (and careful quoted host forms).
    public static func extractHosts(from text: String) -> [String] {
        var found = Set<String>()

        // Prefer explicit URLs — highest signal.
        let urlPattern = #"https?://([A-Za-z0-9.-]+\.[A-Za-z]{2,})(?::\d+)?"#
        // Quoted hosts only when they still look like public DNS names (not module paths).
        let quotedHostPattern = #"[\"']([A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,})[\"']"#

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

    /// User chat text: URLs, quoted hosts, and bare `apple.com`-style names.
    public static func extractHostsFromUserText(_ text: String) -> [String] {
        var found = Set(extractHosts(from: text))
        let barePattern = #"\b([A-Za-z0-9][A-Za-z0-9-]*\.[A-Za-z]{2,})\b"#
        guard let regex = try? NSRegularExpression(pattern: barePattern, options: [.caseInsensitive]) else {
            return found.sorted()
        }
        let range = NSRange(text.startIndex..., in: text)
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, match.numberOfRanges >= 2,
                  let hostRange = Range(match.range(at: 1), in: text) else { return }
            let host = String(text[hostRange]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard isPlausibleHostname(host) else { return }
            found.insert(host)
        }
        return found.sorted()
    }

    public static func isPlausibleHostname(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty,
              normalized.contains("."),
              !normalized.hasPrefix("."),
              !normalized.hasSuffix(".") else {
            return false
        }
        if nonHostNames.contains(normalized) {
            return false
        }
        // Reject multi-label module-style names we know about (prefix match).
        if nonHostNames.contains(where: { normalized == $0 || normalized.hasPrefix($0 + ".") }) {
            return false
        }

        let labels = normalized.split(separator: ".").map(String.init)
        guard labels.count >= 2,
              let tld = labels.last,
              tld.count >= 2,
              tld.count <= 24 else {
            return false
        }
        // TLDs are alphabetic (allow punycode xn-- via letters/digits/hyphen already).
        guard tld.range(of: #"^[a-z]{2,}$"#, options: .regularExpression) != nil else {
            return false
        }
        if nonHostFinalLabels.contains(tld) {
            return false
        }
        // Each label must be DNS-ish.
        guard normalized.range(of: #"^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$"#, options: .regularExpression) != nil else {
            return false
        }
        for label in labels {
            guard !label.isEmpty, !label.hasPrefix("-"), !label.hasSuffix("-") else {
                return false
            }
        }
        return true
    }

    /// Domain suffix to store for permanent allow (registrable-ish: last two labels).
    public static func permanentSuffix(for host: String) -> String {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = normalized.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return normalized }
        return parts.suffix(2).joined(separator: ".")
    }
}
