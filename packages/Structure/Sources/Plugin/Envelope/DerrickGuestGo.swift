import Foundation

/// Go contract shown to models that generate Derrick plugin guest programs.
public enum DerrickGuestGo: Sendable {
    public static let modelContract = """
    Go guest contract:
    - The program is a standalone `package main` built to a Linux binary and run as `/tmp/guest`.
    - Read one JSON object from standard input matching the hop-event schema.
    - Write one JSON array of envelope objects to standard output matching the envelope-list schema.
    - Every envelope object needs `verb` from the envelope-list schema.
    - POST bodies go in `json`. The host decodes `http.request` as HostHTTPRequest and sends `json` as the HTTP body.
    - On the first event, emit `http.request` envelopes for host HTTP.
    - On an `http_results` event, emit `result.emit` or `message.post`.
    - The host, not the guest container, performs HTTP and supplies response bodies.
    - Do not import net/http, net, os/exec, os (except os.Stdin/os.Stdout), or perform filesystem access.
    - Use only the Go standard library.
    - For repeatable output, match HTTP responses by request_id, sort and de-duplicate collections
      by stable keys, and never use current time, randomness, UUIDs, response arrival order, or
      map iteration order for user-visible output.
    - Later http_results events include earlier responses plus the newest ones. Match by request_id.

    Minimal output pattern:
    ```go
    package main

    import (
        "encoding/json"
        "os"
    )

    func main() {
        var event map[string]any
        if err := json.NewDecoder(os.Stdin).Decode(&event); err != nil {
            return
        }
        emit([]map[string]any{{"verb": "result.emit", "title": "Result", "summary": "done"}})
    }

    func emit(envelopes []map[string]any) {
        enc := json.NewEncoder(os.Stdout)
        enc.SetEscapeHTML(false)
        _ = enc.Encode(envelopes)
    }
    ```
    Inspect `event["kind"]` and `event["http_results"]` to choose the next envelopes.
    """

    public static func source(for spec: PluginSpec? = nil) throws -> String {
        var sections = [modelContract]
        sections.append(
            """
            Canonical JSON schemas (Swift host and Go guest must match exactly):
            --- \(GuestContract.Schema.guestRuntime.rawValue) ---
            \(try GuestContract.loadSchemaText(.guestRuntime))

            --- \(GuestContract.Schema.hopEvent.rawValue) ---
            \(try GuestContract.loadSchemaText(.hopEvent))

            --- \(GuestContract.Schema.envelopeList.rawValue) ---
            \(try GuestContract.loadSchemaText(.envelopeList))
            """
        )
        if let spec {
            sections.append(
                """
                Plugin parameters are delivered in the input object's `params` object.
                The parameter contract is:
                \(try spec.goParameterDeclaration())

                --- \(GuestContract.Schema.connectorParams.rawValue) ---
                \(try GuestContract.loadSchemaText(.connectorParams))
                """
            )
        }
        return sections.joined(separator: "\n\n")
    }
}

private extension PluginSpec {
    func goParameterDeclaration() throws -> String {
        _ = try validated()
        let fields = parameters.map { parameter in
            "    \(parameter.name) \(parameterType(parameter.type))"
        }
        return """
        type PluginParams struct {
        \(fields.joined(separator: "\n"))
        }
        """
    }

    func parameterType(_ type: PluginParameterType) -> String {
        switch type {
        case .string:
            return "string"
        case .number:
            return "float64"
        case .boolean:
            return "bool"
        case .stringList:
            return "[]string"
        case .numberList:
            return "[]float64"
        }
    }
}
