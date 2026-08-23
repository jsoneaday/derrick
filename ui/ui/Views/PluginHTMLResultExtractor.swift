import Foundation
import Plugin
import ServiceContracts

struct PluginHTMLPayload {
    let title: String?
    let html: String
}

enum PluginResultPresentationFormat: Equatable {
    case html
    case text
}

struct PluginResultPayload {
    let title: String?
    let body: String
    let format: PluginResultPresentationFormat

    var displayText: String {
        guard let title,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !body.localizedCaseInsensitiveContains(title)
        else {
            return body
        }
        return "\(title)\n\n\(body)"
    }
}

enum PluginResultExtractor {
    static func payload(from raw: String) -> PluginResultPayload? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let outcome = ToolExecutionOutcome.decode(from: trimmed) {
            return payload(from: outcome)
        }

        if let data = trimmed.data(using: .utf8),
           let envelopes = try? PluginEnvelopeList.decode(data) {
            var title: String?
            var htmlFragments: [String] = []
            var textFragments: [String] = []
            for envelope in envelopes where envelope.verb == .resultEmit {
                if title == nil, let candidate = envelope.payload["title"]?.stringValue,
                   !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    title = candidate
                }

                if let html = envelope.payload["html"]?.stringValue,
                   !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    htmlFragments.append(html)
                    continue
                }

                let format = envelope.payload["format"]?.stringValue?.lowercased()
                let candidate = envelope.payload["content"]?.stringValue
                    ?? envelope.payload["summary"]?.stringValue
                    ?? envelope.payload["text"]?.stringValue
                    ?? ""
                guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                if format == "html" {
                    htmlFragments.append(candidate)
                } else {
                    textFragments.append(cleanTextContent(candidate))
                }
            }

            if !htmlFragments.isEmpty {
                return PluginResultPayload(
                    title: title,
                    body: htmlFragments.joined(separator: "\n"),
                    format: .html
                )
            }
            if !textFragments.isEmpty {
                return PluginResultPayload(
                    title: title,
                    body: textFragments.joined(separator: "\n\n"),
                    format: .text
                )
            }
        }

        // Keep presentation resilient to envelope fields added by a plugin.
        // JSONSerialization also accepts otherwise valid JSON that a stricter
        // Codable payload may reject because of an unrelated field.
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let presentation = payload(fromJSONObject: object) {
            return presentation
        }
        if let data = trimmed.data(using: .utf8),
           let encodedString = try? JSONDecoder().decode(String.self, from: data),
           encodedString != trimmed,
           let presentation = payload(from: encodedString) {
            return presentation
        }
        if let unescaped = unescapedJSONEnvelope(from: trimmed),
           let data = unescaped.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let presentation = payload(fromJSONObject: object) {
            return presentation
        }
        if let repaired = repairedJSON(in: trimmed),
           let data = repaired.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let presentation = payload(fromJSONObject: object) {
            return presentation
        }
        if let aggressivelyUnescaped = aggressivelyUnescapedJSON(from: trimmed),
           let data = aggressivelyUnescaped.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let presentation = payload(fromJSONObject: object) {
            return presentation
        }
        if let json = firstJSONValue(in: trimmed),
           json != trimmed,
           let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
           let presentation = payload(fromJSONObject: object) {
            return presentation
        }

        guard HTMLSanitizer.looksLikeHTML(trimmed) else { return nil }
        return PluginResultPayload(title: nil, body: trimmed, format: .html)
    }

    private static func payload(from outcome: ToolExecutionOutcome) -> PluginResultPayload? {
        if let output = outcome.output {
            switch output.format {
            case .html:
                return PluginResultPayload(
                    title: nil,
                    body: output.value,
                    format: .html
                )
            case .json:
                return payload(from: output.value)
                    ?? PluginResultPayload(
                        title: nil,
                        body: output.value,
                        format: .text
                    )
            case .text, .markdown, .csv:
                let format: PluginResultPresentationFormat =
                    HTMLSanitizer.looksLikeHTML(output.value) ? .html : .text
                return PluginResultPayload(
                    title: nil,
                    body: output.value,
                    format: format
                )
            }
        }

        guard outcome.indicatesFailure else { return nil }
        let reasons = outcome.diagnostics.map(\.message).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let reasonText = reasons.isEmpty
            ? "No diagnostic detail was returned."
            : reasons.map { "- \($0)" }.joined(separator: "\n")
        return PluginResultPayload(
            title: "Tool failed",
            body: "The tool failed during \(outcome.stage.rawValue).\n\n\(reasonText)",
            format: .text
        )
    }

    private static func firstJSONValue(in text: String) -> String? {
        var start: String.Index?
        var depth = 0
        var inString = false
        var escaped = false

        for index in text.indices {
            let character = text[index]
            if start == nil {
                guard character == "[" || character == "{" else { continue }
                start = index
                depth = 1
                continue
            }

            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            if character == "\"" {
                inString = true
            } else if character == "[" || character == "{" {
                depth += 1
            } else if character == "]" || character == "}" {
                depth -= 1
                if depth == 0, let start {
                    return String(text[start...index])
                }
            }
        }
        return nil
    }

    private static func unescapedJSONEnvelope(from text: String) -> String? {
        guard (text.hasPrefix("[") || text.hasPrefix("{")),
              text.contains("\\\"") else {
            return nil
        }
        var unescaped = text
        for _ in 0..<3 {
            let next = unescaped
                .replacingOccurrences(of: "\\\\\"", with: "\"")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\/", with: "/")
                .replacingOccurrences(of: "\\/", with: "/")
            if next == unescaped {
                break
            }
            unescaped = next
        }
        return unescaped == text ? nil : unescaped
    }

    private static func aggressivelyUnescapedJSON(from text: String) -> String? {
        guard text.hasPrefix("[") || text.hasPrefix("{") else { return nil }
        let unescaped = text.replacingOccurrences(of: "\\", with: "")
        return unescaped == text ? nil : unescaped
    }

    private static func repairedJSON(in text: String) -> String? {
        var result = ""
        var inString = false
        var escaped = false
        var changed = false

        for character in text {
            if inString {
                if escaped {
                    switch character {
                    case "\n":
                        result.append("n")
                        changed = true
                    case "\r":
                        result.append("r")
                        changed = true
                    case "\t":
                        result.append("t")
                        changed = true
                    case "\"", "\\", "/", "b", "f", "n", "r", "t", "u":
                        result.append(character)
                    default:
                        if result.last == "\\" {
                            result.removeLast()
                        }
                        result.append(character)
                        changed = true
                    }
                    escaped = false
                } else if character == "\\" {
                    result.append(character)
                    escaped = true
                } else if character == "\"" {
                    result.append(character)
                    inString = false
                } else if character == "\n" {
                    result.append("\\n")
                    changed = true
                } else if character == "\r" {
                    result.append("\\r")
                    changed = true
                } else if character == "\t" {
                    result.append("\\t")
                    changed = true
                } else {
                    result.append(character)
                }
            } else {
                result.append(character)
                if character == "\"" {
                    inString = true
                }
            }
        }
        return changed ? result : nil
    }

    private static func payload(fromJSONObject object: Any) -> PluginResultPayload? {
        if let array = object as? [[String: Any]] {
            var title: String?
            var htmlFragments: [String] = []
            var textFragments: [String] = []

            for item in array {
                let verb = (item["verb"] as? String ?? item["type"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let isResult = verb == nil
                    || verb == "result.emit"
                    || verb == "result"
                    || verb == "emit"
                    || verb == "done"
                guard isResult else { continue }

                if title == nil, let candidate = item["title"] as? String,
                   !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    title = candidate
                }
                if let html = item["html"] as? String,
                   !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    htmlFragments.append(html)
                    continue
                }

                let candidate = item["content"] as? String
                    ?? item["summary"] as? String
                    ?? item["text"] as? String
                    ?? ""
                guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                let format = (item["format"] as? String)?.lowercased()
                if format == "html" {
                    htmlFragments.append(candidate)
                } else {
                    textFragments.append(cleanTextContent(candidate))
                }
            }

            if !htmlFragments.isEmpty {
                return PluginResultPayload(
                    title: title,
                    body: htmlFragments.joined(separator: "\n"),
                    format: .html
                )
            }
            if !textFragments.isEmpty {
                return PluginResultPayload(
                    title: title,
                    body: textFragments.joined(separator: "\n\n"),
                    format: .text
                )
            }
        }

        if let dictionary = object as? [String: Any] {
            if let output = dictionary["output"] as? [String: Any],
               let value = output["value"] as? String {
                return payload(fromEncodedValue: value)
            }
            if let value = dictionary["value"] as? String {
                return payload(fromEncodedValue: value)
            }
            if let text = dictionary["text"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return PluginResultPayload(
                    title: dictionary["title"] as? String,
                    body: text,
                    format: HTMLSanitizer.looksLikeHTML(text) ? .html : .text
                )
            }
        }

        return nil
    }

    private static func payload(fromEncodedValue value: String) -> PluginResultPayload? {
        if let presentation = payload(from: value) {
            return presentation
        }
        if let repaired = repairedJSON(in: value),
           let presentation = payload(from: repaired) {
            return presentation
        }
        let unescaped = value
            .replacingOccurrences(of: "\\\\\"", with: "\"")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\'", with: "'")
            .replacingOccurrences(of: "\\\r\n", with: "\r\n")
            .replacingOccurrences(of: "\\\n", with: "\n")
            .replacingOccurrences(of: "\\\\\r\n", with: "\r\n")
            .replacingOccurrences(of: "\\\\\n", with: "\n")
            .replacingOccurrences(of: "\\\\n", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\\/", with: "/")
            .replacingOccurrences(of: "\\/", with: "/")
        return unescaped == value ? nil : payload(from: unescaped)
    }

    private static func cleanTextContent(_ raw: String) -> String {
        // A text/Markdown result may contain harmless RSS tags such as </i>.
        // Remove those tags without flattening the newlines that define Markdown.
        let newlineMarker = "\u{E000}"
        let marked = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: newlineMarker)
        return PluginMarkup.strip(marked)
            .replacingOccurrences(of: newlineMarker, with: "\n")
    }
}

enum PluginHTMLResultExtractor {
    static func payload(from raw: String) -> PluginHTMLPayload? {
        guard let result = PluginResultExtractor.payload(from: raw),
              result.format == .html else {
            return nil
        }
        return PluginHTMLPayload(title: result.title, html: result.body)
    }
}
