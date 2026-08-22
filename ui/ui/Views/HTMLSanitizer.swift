import Foundation
import Plugin

/// Sanitizes untrusted HTML before it reaches the native rich-text renderer.
enum HTMLSanitizer {
    private static let allowedTags: Set<String> = [
        "a", "article", "aside", "b", "blockquote", "br", "code", "dd", "del",
        "div", "dl", "dt", "em", "footer", "h1", "h2", "h3", "h4", "h5", "h6",
        "header", "hr", "i", "ins", "li", "main", "mark", "ol", "p", "pre",
        "section", "small", "s", "span", "strong", "sub", "sup", "table", "tbody",
        "td", "tfoot", "th", "thead", "tr", "u", "ul",
    ]

    private static let dangerousBlockTags = [
        "embed", "form", "head", "iframe", "math", "object", "script", "style", "svg",
    ]

    static func looksLikeHTML(_ value: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: #"</?\s*(?:a|article|aside|b|blockquote|br|code|dd|del|div|dl|dt|em|footer|h[1-6]|header|hr|i|ins|li|main|mark|ol|p|pre|s|script|section|small|span|strong|style|sub|sup|table|tbody|td|tfoot|th|thead|tr|u|ul)\b[^>]*>"#,
            options: .caseInsensitive
        ) else {
            return false
        }
        return regex.firstMatch(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        ) != nil
    }

    static func sanitize(_ raw: String) -> String {
        var html = raw
        html = removeComments(from: html)
        for tag in dangerousBlockTags {
            html = replace(
                in: html,
                pattern: #"<\#(tag)\b[^>]*>[\s\S]*?</\#(tag)\s*>"#,
                options: .caseInsensitive,
                with: ""
            )
        }
        return sanitizeTags(in: html)
    }

    static func plainText(_ raw: String) -> String {
        PluginMarkup.strip(raw)
    }

    private static func removeComments(from html: String) -> String {
        replace(
            in: html,
            pattern: #"<!--[\s\S]*?-->"#,
            options: [],
            with: ""
        )
    }

    private static func sanitizeTags(in html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"<\s*(/?)\s*([A-Za-z][A-Za-z0-9:-]*)([^>]*)>"#,
            options: .caseInsensitive
        ) else {
            return html
        }

        let fullRange = NSRange(html.startIndex..., in: html)
        var replacements: [(Range<String.Index>, String)] = []
        regex.enumerateMatches(in: html, range: fullRange) { match, _, _ in
            guard let match,
                  let full = Range(match.range, in: html),
                  let closingRange = Range(match.range(at: 1), in: html),
                  let nameRange = Range(match.range(at: 2), in: html),
                  let attributesRange = Range(match.range(at: 3), in: html)
            else {
                return
            }

            let name = String(html[nameRange]).lowercased()
            guard allowedTags.contains(name) else {
                replacements.append((full, ""))
                return
            }

            let isClosing = !html[closingRange].isEmpty
            if isClosing {
                replacements.append((full, "</\(name)>"))
                return
            }

            if name == "a" {
                let attributes = String(html[attributesRange])
                if let href = safeHref(from: attributes) {
                    replacements.append((full, "<a href=\"\(escapeAttribute(href))\">"))
                } else {
                    replacements.append((full, ""))
                }
                return
            }

            if name == "br" || name == "hr" {
                replacements.append((full, "<\(name)/>"))
            } else {
                replacements.append((full, "<\(name)>"))
            }
        }

        var sanitized = html
        for (range, replacement) in replacements.reversed() {
            sanitized.replaceSubrange(range, with: replacement)
        }
        return sanitized
    }

    private static func safeHref(from attributes: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#,
            options: .caseInsensitive
        ),
        let match = regex.firstMatch(
            in: attributes,
            range: NSRange(attributes.startIndex..., in: attributes)
        ) else {
            return nil
        }

        let value: String
        if let range = Range(match.range(at: 1), in: attributes) {
            value = String(attributes[range])
        } else if let range = Range(match.range(at: 2), in: attributes) {
            value = String(attributes[range])
        } else if let range = Range(match.range(at: 3), in: attributes) {
            value = String(attributes[range])
        } else {
            return nil
        }

        let decoded = value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = URL(string: decoded)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return nil
        }
        return decoded
    }

    private static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func replace(
        in value: String,
        pattern: String,
        options: NSRegularExpression.Options,
        with replacement: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return value
        }
        return regex.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: replacement
        )
    }
}
