import Foundation
import MCP

/// Parse tool-call `arguments` into MCP Values.
///
/// Tool arguments are **double-encoded**: outer AgentResponse JSON contains `arguments`
/// as a string of JSON. After outer decode that string is often invalid JSON because
/// unescaping already happened (`\"` → `"`, `\n` → newline, etc.).
///
/// We re-escape string contents with a small state machine that tracks object/array depth
/// so structural `"` terminators stay terminators while content quotes are escaped.
public func parseToolArgumentsObject(_ json: String) throws -> [String: Value] {
    let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return [:]
    }

    if let dict = tryParseJSONObject(trimmed) {
        return dict.mapValues { jsonToToolValue($0) }
    }

    let repaired = reescapeJSONDocumentAfterOuterDecode(trimmed)
    if let dict = tryParseJSONObject(repaired) {
        return dict.mapValues { jsonToToolValue($0) }
    }

    throw NSError(
        domain: "Lib",
        code: 400,
        userInfo: [NSLocalizedDescriptionKey: "Tool arguments are not valid JSON."]
    )
}

public func toolArgumentsFromJSON(_ json: String) throws -> [String: Value] {
    if json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return [:]
    }
    if let values = try? parseToolArgumentsObject(json) {
        return values
    }
    return [:]
}

// MARK: - Re-escape after outer JSON decode

/// Rebuild a JSON document so string values are legal JSON after outer unescaping.
public func reescapeJSONDocumentAfterOuterDecode(_ input: String) -> String {
    var output = ""
    output.reserveCapacity(input.utf8.count + 64)

    var i = input.startIndex
    var inString = false
    var escaped = false
    /// Stack of `{` / `[` for depth; used to decide if a closing `"` is structural.
    var containerStack: [ContainerKind] = []
    /// After a key string we expect `:`; after a value we expect `,` or container close.
    var expectingKey = true

    while i < input.endIndex {
        let ch = input[i]
        let next = input.index(after: i)

        if !inString {
            switch ch {
            case "{":
                containerStack.append(.object)
                expectingKey = true
                output.append(ch)
            case "[":
                containerStack.append(.array)
                expectingKey = false
                output.append(ch)
            case "}":
                if containerStack.last == .object {
                    containerStack.removeLast()
                }
                expectingKey = false
                output.append(ch)
            case "]":
                if containerStack.last == .array {
                    containerStack.removeLast()
                }
                expectingKey = false
                output.append(ch)
            case ":":
                expectingKey = false
                output.append(ch)
            case ",":
                expectingKey = (containerStack.last == .object)
                output.append(ch)
            case "\"":
                inString = true
                escaped = false
                output.append(ch)
            default:
                output.append(ch)
            }
            i = next
            continue
        }

        // Inside string
        if escaped {
            output.append(ch)
            escaped = false
            i = next
            continue
        }

        if ch == "\\" {
            if next >= input.endIndex {
                output.append("\\\\")
                i = next
                continue
            }
            let following = input[next]
            if isLegalJSONEscapeScalar(following) {
                output.append("\\")
                output.append(following)
                if following == "u" {
                    var j = input.index(after: next)
                    var hexCount = 0
                    while hexCount < 4, j < input.endIndex, input[j].isHexDigit {
                        output.append(input[j])
                        j = input.index(after: j)
                        hexCount += 1
                    }
                    i = j
                    continue
                }
                i = input.index(after: next)
                continue
            }
            output.append("\\\\")
            output.append(following)
            i = input.index(after: next)
            continue
        }

        if ch == "\"" {
            if isStructuralStringEnd(
                input,
                after: next,
                containerStack: containerStack,
                expectingKey: expectingKey
            ) {
                inString = false
                output.append("\"")
                // After a key string, still waiting for `:`. After a value string, value complete.
                // expectingKey unchanged until we see `:` or `,`.
            } else {
                output.append("\\\"")
            }
            i = next
            continue
        }

        switch ch {
        case "\n":
            output.append("\\n")
        case "\r":
            output.append("\\r")
        case "\t":
            output.append("\\t")
        case "\u{08}":
            output.append("\\b")
        case "\u{0C}":
            output.append("\\f")
        default:
            if ch.unicodeScalars.allSatisfy({ $0.value < 0x20 }) {
                for scalar in ch.unicodeScalars {
                    output.append(contentsOf: String(format: "\\u%04x", scalar.value))
                }
            } else {
                output.append(ch)
            }
        }
        i = next
    }

    return output
}

public func sanitizeIllegalJSONEscapes(in input: String) -> String {
    reescapeJSONDocumentAfterOuterDecode(input)
}

public func escapeBareQuotesInsideJSONStrings(_ input: String) -> String {
    reescapeJSONDocumentAfterOuterDecode(input)
}

// MARK: - Private

private enum ContainerKind {
    case object
    case array
}

/// Decide whether an unescaped `"` ends the current JSON string (structural) or is content.
private func isStructuralStringEnd(
    _ input: String,
    after index: String.Index,
    containerStack: [ContainerKind],
    expectingKey: Bool
) -> Bool {
    var j = index
    while j < input.endIndex {
        let c = input[j]
        if c == " " || c == "\t" || c == "\n" || c == "\r" {
            j = input.index(after: j)
            continue
        }
        break
    }
    if j >= input.endIndex {
        return true
    }

    let c = input[j]
    switch c {
    case ":":
        // Only keys are followed by `:`.
        return expectingKey && containerStack.last == .object
    case ",":
        return true
    case "}":
        return containerStack.last == .object
    case "]":
        return containerStack.last == .array
    default:
        return false
    }
}

private func isLegalJSONEscapeScalar(_ ch: Character) -> Bool {
    switch ch {
    case "\"", "\\", "/", "b", "f", "n", "r", "t", "u":
        return true
    default:
        return false
    }
}

private func tryParseJSONObject(_ json: String) -> [String: Any]? {
    guard let data = json.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data),
          let dict = obj as? [String: Any] else {
        return nil
    }
    return dict
}

private extension Character {
    var isHexDigit: Bool {
        ("0"..."9").contains(self) || ("a"..."f").contains(self) || ("A"..."F").contains(self)
    }
}
