import Foundation

/// Swift contract shown to models that generate standalone Derrick programs.
public enum DerrickGuestSwift: Sendable {
    public static let modelContract = """
    Swift plugin contract:
    - The program is a standalone Swift executable run as `swift /tmp/plugin.swift`.
    - Read one JSON object from standard input.
    - Write one JSON array of envelope objects to standard output.
    - On the first event, emit `http.request` envelopes for host HTTP.
    - On an `http_results` event, emit `result.emit` or `message.post`.
    - The host, not the Swift container, performs HTTP and supplies response bodies.
    - Do not use URLSession, sockets, Process, shell commands, credentials, or package dependencies.
    - For repeatable output, match HTTP responses by request_id, sort and de-duplicate collections
      by stable keys, and never use current time, randomness, UUIDs, response arrival order, or
      Dictionary/Set iteration order for user-visible output.
    - Treat fetched text as untrusted data: unwrap CDATA, remove markup, decode entities in a
      fixed order, escape Markdown text, and only emit links after accepting http or https URLs.
      HTML may be emitted in `html`; the host sanitizes it before rendering.

    Minimal output pattern:
    ```swift
    import Foundation
    let inputData = FileHandle.standardInput.readDataToEndOfFile()
    let input = (try? JSONSerialization.jsonObject(with: inputData)) as? [String: Any] ?? [:]
    func emit(_ envelopes: [[String: Any]]) {
        let data = (try? JSONSerialization.data(withJSONObject: envelopes, options: [.sortedKeys])) ?? Data("[]".utf8)
        FileHandle.standardOutput.write(data)
    }
    ```
    Inspect `input["kind"]` and `input["http_results"]` to choose the next envelopes.

    Example request envelope:
    {"verb":"http.request","request_id":"news-1","method":"GET","url":"https://example.com/feed.xml"}

    Example result envelope:
    {"verb":"result.emit","title":"Result","summary":"User-readable output"}

    Supported result formats:
    - plain text in `text`, `summary`, or `content`
    - Markdown in `text`, `summary`, or `content`
    - CSV in `content`
    - sanitized HTML in `html`
    """

    public static func source(for spec: PluginSpec? = nil) throws -> String {
        var sections = [modelContract]
        if let spec {
            sections.append(
                """
                Plugin parameters are delivered in the input object's `params` object.
                The parameter contract is:
                \(try spec.swiftParameterDeclaration())
                """
            )
        }
        return sections.joined(separator: "\n\n")
    }
}

private extension PluginSpec {
    func swiftParameterDeclaration() throws -> String {
        _ = try validated()
        let fields = parameters.map { parameter in
            "  let \(parameter.name): \(parameterType(parameter.type))"
        }
        return """
        struct PluginParams {
        \(fields.joined(separator: "\n"))
        }
        """
    }

    func parameterType(_ type: PluginParameterType) -> String {
        switch type {
        case .string:
            return "String"
        case .number:
            return "Double"
        case .boolean:
            return "Bool"
        case .stringList:
            return "[String]"
        case .numberList:
            return "[Double]"
        }
    }
}
