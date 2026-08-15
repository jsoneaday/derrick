import Foundation

/// Canonical JSON Schema for `handle()` stdout. RAG text is `ragSection` (includes generated TS).
public enum PluginEnvelopeSchema {
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
