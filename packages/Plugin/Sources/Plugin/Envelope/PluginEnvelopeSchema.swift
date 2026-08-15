import Foundation

/// Canonical JSON Schema for `handle()` stdout. Same text is injected into conversation RAG.
public enum PluginEnvelopeSchema {
    public static let ragSection = """
    # handle() return (JSON wire)

    `export function handle(event)` runs in Bun. Swift decodes **stdout only**.
    Return value MUST be a JSON **array** of envelope objects. Never a string, number, or bare object.
    One result → an array of one element.

    ```json
    \(jsonSchema)
    ```

    Examples:
    `[{ "verb": "http.request", "method": "GET", "url": "https://example.com" }]`
    `[{ "verb": "result.emit", "title": "Apple", "summary": "…" }]`
    `return netFetch({ url: "https://example.com" })` — `netFetch` already returns an array.
    """

    public static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://derrick.local/schemas/handle-return.json",
      "title": "handle() return",
      "type": "array",
      "minItems": 0,
      "items": {
        "type": "object",
        "required": ["verb"],
        "properties": {
          "verb": {
            "type": "string",
            "enum": [
              "http.request",
              "result.emit",
              "message.post",
              "ui.present",
              "secret.request",
              "job.schedule",
              "log"
            ]
          },
          "type": { "type": "string", "description": "Alias for verb" },
          "request_id": { "type": "string" },
          "method": { "type": "string" },
          "url": { "type": "string" },
          "title": { "type": "string" },
          "summary": { "type": "string" },
          "text": { "type": "string" },
          "content": { "type": "string" },
          "message": { "type": "string" }
        }
      }
    }
    """
}
