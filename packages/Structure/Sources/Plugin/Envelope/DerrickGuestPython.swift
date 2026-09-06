import Foundation

/// Python contract shown to models that generate standalone Derrick guest programs.
public enum DerrickGuestPython: Sendable {
    public static let modelContract = """
    Python guest contract:
    - The program is a standalone Python script run as `python3 /tmp/guest.py`.
    - Read one JSON object from standard input (`sys.stdin`).
    - Write one JSON array of envelope objects to standard output. Every object needs `verb` from the envelope-list schema.
    - POST bodies go in `json`. The host decodes `http.request` as HostHTTPRequest and sends `json` as the HTTP body.
    - On the first event, emit `http.request` envelopes for host HTTP.
    - On an `http_results` event, emit `result.emit` or `message.post`.
    - The host, not the Python container, performs HTTP and supplies response bodies.
    - Do not use socket, urllib, requests, httpx, subprocess, or filesystem access.
    - Use only the Python standard library (no pip/uv dependencies in script_exec).
    - For repeatable output, match HTTP responses by request_id, sort and de-duplicate collections
      by stable keys, and never use current time, randomness, UUIDs, response arrival order, or
      dict/set iteration order for user-visible output.
    - Later http_results events include earlier responses plus the newest ones. Match by request_id.

    Minimal output pattern:
    ```python
    import json, sys
    event = json.load(sys.stdin)
    def emit(envelopes):
        json.dump(envelopes, sys.stdout, separators=(",", ":"))
    ```
    Inspect `event.get("kind")` and `event.get("http_results")` to choose the next envelopes.

    Example request envelope:
    {"verb":"http.request","request_id":"news-1","method":"GET","url":"https://example.com/feed.xml"}

    POST bodies: put the JSON value in `json`. The host deserializes `http.request` into HostHTTPRequest and sends `json` as the HTTP body.
    {"verb":"http.request","request_id":"send-1","method":"POST","url":"https://example.com/api","headers":{"Content-Type":"application/json"},"json":{"channel":"C1","text":"hello"}}

    Example result envelope:
    {"verb":"result.emit","title":"Result","summary":"User-readable output"}
    """

    public static func source(for spec: PluginSpec? = nil) throws -> String {
        var sections = [modelContract]
        if let spec {
            sections.append(
                """
                Plugin parameters are delivered in the input object's `params` object.
                The parameter contract is:
                \(try spec.pythonParameterDeclaration())
                """
            )
        }
        return sections.joined(separator: "\n\n")
    }
}

private extension PluginSpec {
    func pythonParameterDeclaration() throws -> String {
        _ = try validated()
        let fields = parameters.map { parameter in
            "    \(parameter.name): \(parameterType(parameter.type))"
        }
        return """
        class PluginParams(TypedDict):
        \(fields.joined(separator: "\n"))
        """
    }

    func parameterType(_ type: PluginParameterType) -> String {
        switch type {
        case .string:
            return "str"
        case .number:
            return "float"
        case .boolean:
            return "bool"
        case .stringList:
            return "list[str]"
        case .numberList:
            return "list[float]"
        }
    }
}
