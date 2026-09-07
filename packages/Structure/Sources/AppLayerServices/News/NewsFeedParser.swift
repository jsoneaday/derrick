import Foundation

public enum NewsFeedParser {
    public static func parse(data: Data, sourceLabel: String, fallbackPageURL: URL) -> [ParsedNewsEntry] {
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        if NewsPaywall.looksLikeFeed(text) {
            return parseXMLFeed(text, sourceLabel: sourceLabel)
        }
        if let entry = htmlFallback(text: text, sourceLabel: sourceLabel, url: fallbackPageURL) {
            return [entry]
        }
        return []
    }

    public struct ParsedNewsEntry: Sendable, Hashable {
        public var title: String
        public var sourceURL: String
        public var summary: String?
        public var publishedAt: Date?

        public init(title: String, sourceURL: String, summary: String? = nil, publishedAt: Date? = nil) {
            self.title = title
            self.sourceURL = sourceURL
            self.summary = summary
            self.publishedAt = publishedAt
        }
    }

    private static func parseXMLFeed(_ xml: String, sourceLabel: String) -> [ParsedNewsEntry] {
        _ = sourceLabel
        var entries: [ParsedNewsEntry] = []
        let itemBlocks = slices(of: xml, start: "<item", end: "</item>")
            + slices(of: xml, start: "<entry", end: "</entry>")
        for block in itemBlocks {
            let title = firstTag(block, names: ["title"]) ?? ""
            let link = firstTag(block, names: ["link"])
                ?? attribute(named: "href", in: firstRawTag(block, name: "link") ?? "")
                ?? firstTag(block, names: ["guid", "id"])
                ?? ""
            let summary = firstTag(block, names: ["description", "summary", "content"])
            let dateText = firstTag(block, names: ["pubDate", "published", "updated", "dc:date"])
            let cleanedTitle = stripTags(title).trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedLink = stripTags(link).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedTitle.isEmpty, let url = URL(string: cleanedLink), url.scheme != nil else {
                continue
            }
            entries.append(
                ParsedNewsEntry(
                    title: cleanedTitle,
                    sourceURL: url.absoluteString,
                    summary: summary.map(stripTags).flatMap { $0.isEmpty ? nil : $0 },
                    publishedAt: parseDate(dateText)
                )
            )
        }
        return entries
    }

    private static func htmlFallback(text: String, sourceLabel: String, url: URL) -> ParsedNewsEntry? {
        _ = sourceLabel
        let title = firstTag(text, names: ["title"])
            .map(stripTags)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else { return nil }
        return ParsedNewsEntry(title: title, sourceURL: url.absoluteString, summary: nil, publishedAt: nil)
    }

    private static func slices(of text: String, start: String, end: String) -> [String] {
        var result: [String] = []
        let startLower = start.lowercased()
        let endLower = end.lowercased()
        let lower = text.lowercased()
        var idx = lower.startIndex
        while let startRange = lower[idx...].range(of: startLower) {
            guard let endRange = lower[startRange.upperBound...].range(of: endLower) else { break }
            let sliceStart = startRange.lowerBound
            let sliceEnd = endRange.upperBound
            result.append(String(text[sliceStart..<sliceEnd]))
            idx = sliceEnd
        }
        return result
    }

    private static func firstTag(_ xml: String, names: [String]) -> String? {
        for name in names {
            let lower = xml.lowercased()
            let open = "<\(name.lowercased())"
            guard let openStart = lower.range(of: open) else { continue }
            guard let tagClose = xml[openStart.upperBound...].firstIndex(of: ">") else { continue }
            let innerStart = xml.index(after: tagClose)
            let closeToken = "</\(name.lowercased())>"
            guard let close = lower[innerStart...].range(of: closeToken) else { continue }
            return String(xml[innerStart..<close.lowerBound])
        }
        return nil
    }

    private static func firstRawTag(_ xml: String, name: String) -> String? {
        let lower = xml.lowercased()
        let open = "<\(name.lowercased())"
        guard let openStart = lower.range(of: open) else { return nil }
        guard let tagClose = xml[openStart.upperBound...].firstIndex(of: ">") else { return nil }
        return String(xml[openStart.lowerBound...tagClose])
    }

    private static func attribute(named name: String, in tag: String) -> String? {
        let pattern = "\(name)\\s*=\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        guard let match = regex.firstMatch(in: tag, range: range), match.numberOfRanges > 1,
              let inner = Range(match.range(at: 1), in: tag)
        else {
            return nil
        }
        return String(tag[inner])
    }

    private static func stripTags(_ raw: String) -> String {
        var value = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&nbsp;", " "),
        ]
        for (from, to) in entities {
            value = value.replacingOccurrences(of: from, with: to)
        }
        return value
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let rfc = DateFormatter()
        rfc.locale = Locale(identifier: "en_US_POSIX")
        rfc.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        if let date = rfc.date(from: trimmed) { return date }
        rfc.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = rfc.date(from: trimmed) { return date }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: trimmed)
    }
}
