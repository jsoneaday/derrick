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

    for candidate in trailingBraceCandidates(trimmed) {
        if let dict = tryParseJSONObject(candidate) {
            return dict.mapValues { jsonToToolValue($0) }
        }
    }

    // After outer AgentResponse decode, string values often contain raw newlines / bare quotes.
    let repaired = reescapeJSONDocumentAfterOuterDecode(trimmed)
    for candidate in trailingBraceCandidates(repaired) {
        if let dict = tryParseJSONObject(candidate) {
            return dict.mapValues { jsonToToolValue($0) }
        }
    }

    // Model output often truncates mid-string (nested jobs_create + script is large when
    // double-encoded). Close open strings/containers then re-escape again.
    let closed = closeIncompleteJSONDocument(repaired)
    let closedRescued = reescapeJSONDocumentAfterOuterDecode(closed)
    for candidate in trailingBraceCandidates(closedRescued) + trailingBraceCandidates(closed) {
        if let dict = tryParseJSONObject(candidate) {
            return dict.mapValues { jsonToToolValue($0) }
        }
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

/// Encode MCP tool arguments for transport (e.g. MCPService XPC `argumentsJSON`).
public func toolArgumentsToJSON(_ arguments: [String: Value]) throws -> String {
    let jsonDict = arguments.mapValues { toolValueToJSONObject($0) }
    let jsonData = try JSONSerialization.data(withJSONObject: jsonDict, options: [.sortedKeys])
    return String(data: jsonData, encoding: .utf8) ?? "{}"
}

private func toolValueToJSONObject(_ val: Value) -> Any {
    switch val {
    case .string(let s): return s
    case .int(let i): return i
    case .double(let d): return d
    case .bool(let b): return b
    case .array(let arr): return arr.map { toolValueToJSONObject($0) }
    case .object(let obj): return obj.mapValues { toolValueToJSONObject($0) }
    case .null: return NSNull()
    case .data(_, let data): return data.base64EncodedString()
    }
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

/// Append missing `"` / `}` / `]` so a truncated JSON document can be parsed.
/// Used when the model hits token limits mid tool-arguments string.
public func closeIncompleteJSONDocument(_ input: String) -> String {
    var inString = false
    var escaped = false
    var stack: [ContainerKind] = []

    for ch in input {
        if !inString {
            switch ch {
            case "{": stack.append(.object)
            case "[": stack.append(.array)
            case "}":
                if stack.last == .object { stack.removeLast() }
            case "]":
                if stack.last == .array { stack.removeLast() }
            case "\"":
                inString = true
                escaped = false
            default:
                break
            }
            continue
        }

        if escaped {
            escaped = false
            continue
        }
        if ch == "\\" {
            escaped = true
            continue
        }
        if ch == "\"" {
            inString = false
        }
    }

    var output = input
    if inString {
        // Dangling backslash at end would escape the closing quote.
        if escaped, output.last == "\\" {
            output.removeLast()
        }
        output.append("\"")
    }
    while let kind = stack.popLast() {
        switch kind {
        case .object: output.append("}")
        case .array: output.append("]")
        }
    }
    return output
}

// MARK: - Private

/// PartialJSON / nested `tool_call.arguments` decode can glue an extra outer `}` onto the payload.
private func trailingBraceCandidates(_ json: String) -> [String] {
    var candidates: [String] = []
    var current = json
    candidates.append(current)
    var extraBraces = 0
    while extraBraces < 3, current.hasSuffix("}"), current.count > 2 {
        current.removeLast()
        extraBraces += 1
        candidates.append(current)
    }
    return candidates
}

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
