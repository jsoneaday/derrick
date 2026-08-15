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
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Guest used `/<[^>]*>/` without unwrapping CDATA or `stripMarkup`.
    public static func naiveTagStripFinding(_ source: String) -> String? {
        guard source.contains("/<[^>]*>/") else { return nil }
        if source.range(of: "CDATA", options: .caseInsensitive) != nil { return nil }
        if source.contains("stripMarkup") { return nil }
        return "Do not strip HTML with /<[^>]*>/ on RSS/HTML that may contain CDATA; that deletes titles. Import stripMarkup from derrick."
    }
}
