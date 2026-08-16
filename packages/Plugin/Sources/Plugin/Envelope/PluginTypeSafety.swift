import Foundation

/// Guest TypeScript: `any` is never legal. `unknown` is legal only when `tsc` can force a narrow.
/// Assertions (`as T`) and `@ts-ignore` skip that check, so they are banned too.
public enum PluginTypeSafety: Sendable {
    public static func findings(in script: String) -> [String] {
        var findings: [String] = []
        let directives: [(String, String)] = [
            ("@ts-ignore", "@ts-ignore is not allowed."),
            ("@ts-nocheck", "@ts-nocheck is not allowed."),
            ("@ts-expect-error", "@ts-expect-error is not allowed."),
        ]
        var seen = Set<String>()
        for (token, message) in directives {
            if script.contains(token), seen.insert(message).inserted {
                findings.append(message)
            }
        }
        let text = stripComments(script)
        let rules: [(String, String)] = [
            (
                ":\\s*any\\b",
                "any is not allowed (including annotations). Use a base type or unknown plus a typeof/in/instanceof check."
            ),
            (
                "\\bas\\s+any\\b",
                "as any is not allowed."
            ),
            (
                "<\\s*any\\s*>",
                "any is not allowed as a type argument."
            ),
            (
                "\\bany\\s*\\[\\s*\\]",
                "any[] is not allowed."
            ),
            (
                "\\bArray\\s*<\\s*any\\s*>",
                "Array<any> is not allowed."
            ),
            (
                "\\bPromise\\s*<\\s*any\\s*>",
                "Promise<any> is not allowed."
            ),
            (
                "Record\\s*<\\s*[^>]+,\\s*any\\s*>",
                "Record<…, any> is not allowed."
            ),
            (
                "\\bas\\s+unknown\\s+as\\b",
                "as unknown as T is not allowed. Narrow with typeof, in, or instanceof."
            ),
            (
                "\\bas\\s+(?!const\\b)(?:[A-Za-z_<{])",
                "Type assertions (as T) are not allowed. Narrow unknown with typeof, in, or instanceof."
            ),
        ]
        for (pattern, message) in rules {
            if text.range(of: pattern, options: .regularExpression) != nil, seen.insert(message).inserted {
                findings.append(message)
            }
        }
        return findings
    }

    private static func stripComments(_ script: String) -> String {
        var text = script
        if let blocks = try? NSRegularExpression(pattern: "/\\*[\\s\\S]*?\\*/") {
            text = blocks.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text),
                withTemplate: " "
            )
        }
        if let lines = try? NSRegularExpression(pattern: "//[^\\n]*") {
            text = lines.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text),
                withTemplate: " "
            )
        }
        return text
    }
}
