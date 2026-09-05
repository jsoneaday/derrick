import Foundation

/// HTML / RSS text helpers. `/<[^>]*>/` on a string that still contains
/// `<![CDATA[headline]]>` deletes the headline (the CDATA opener is a tag).
public enum PluginMarkup {
    /// Unwrap CDATA, drop tags, decode a few entities.
    public static func strip(_ raw: String) -> String {
        var text = raw
        let cdata = try? NSRegularExpression(pattern: #"<!\[CDATA\[([\s\S]*?)\]\]>"#, options: .caseInsensitive)
        if let cdata {
            text = cdata.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: "$1"
            )
        }
        let tags = try? NSRegularExpression(pattern: #"<[^>]+>"#)
        if let tags {
            text = tags.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: " "
            )
        }
        return text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'", options: .caseInsensitive)
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Headlines from a news HTML page, or from RSS/Atom if that is what was fetched.
    public static func headlines(_ raw: String, max: Int = 8) -> [String] {
        let fromFeed = feedTitles(raw, max: max)
        if !fromFeed.isEmpty { return fromFeed }
        return htmlTitles(raw, max: max)
    }

    /// Guest used `/<[^>]*>/` without unwrapping CDATA or `stripMarkup`.
    public static func naiveTagStripFinding(_ source: String) -> String? {
        guard source.contains("/<[^>]*>/") else { return nil }
        if source.range(of: "CDATA", options: .caseInsensitive) != nil { return nil }
        if source.contains("stripMarkup") { return nil }
        return "Do not strip HTML with /<[^>]*>/ on a page that may contain CDATA; that deletes titles. Import headlines or stripMarkup from derrick."
    }

    private static func feedTitles(_ raw: String, max: Int) -> [String] {
        collect(
            in: raw,
            patterns: [
                #"<item\b[\s\S]*?<title[^>]*>([\s\S]*?)</title>"#,
                #"<entry\b[\s\S]*?<title[^>]*>([\s\S]*?)</title>"#,
            ],
            max: max
        )
    }

    private static func htmlTitles(_ raw: String, max: Int) -> [String] {
        collect(in: raw, patterns: [#"<h[1-3][^>]*>([\s\S]*?)</h[1-3]>"#], max: max)
    }

    private static func collect(in raw: String, patterns: [String], max: Int) -> [String] {
        var seen = Set<String>()
        var all: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }
            let range = NSRange(raw.startIndex..., in: raw)
            regex.enumerateMatches(in: raw, range: range) { match, _, stop in
                guard let match, match.numberOfRanges >= 2,
                      let inner = Range(match.range(at: 1), in: raw) else { return }
                let title = strip(String(raw[inner]))
                guard title.count >= 12, title.count <= 200, !seen.contains(title) else { return }
                seen.insert(title)
                all.append(title)
                if all.count >= max { stop.pointee = true }
            }
            if !all.isEmpty { return all }
        }
        return all
    }
}
