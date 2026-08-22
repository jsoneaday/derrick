import Foundation
import Plugin

struct PluginHTMLPayload {
    let title: String?
    let html: String
}

enum PluginHTMLResultExtractor {
    static func payload(from raw: String) -> PluginHTMLPayload? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let envelopes = try? PluginEnvelopeList.decode(data) {
            var title: String?
            var fragments: [String] = []
            for envelope in envelopes where envelope.verb == .resultEmit {
                if title == nil, let candidate = envelope.payload["title"]?.stringValue,
                   !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    title = candidate
                }

                if let html = envelope.payload["html"]?.stringValue,
                   !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    fragments.append(html)
                    continue
                }

                let format = envelope.payload["format"]?.stringValue?.lowercased()
                let candidate = envelope.payload["content"]?.stringValue
                    ?? envelope.payload["summary"]?.stringValue
                    ?? envelope.payload["text"]?.stringValue
                    ?? ""
                if format == "html" || HTMLSanitizer.looksLikeHTML(candidate) {
                    fragments.append(candidate)
                }
            }

            if !fragments.isEmpty {
                return PluginHTMLPayload(title: title, html: fragments.joined(separator: "\n"))
            }
            return nil
        }

        guard HTMLSanitizer.looksLikeHTML(trimmed) else { return nil }
        return PluginHTMLPayload(title: nil, html: trimmed)
    }
}
