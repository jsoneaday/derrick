import Foundation

/// Canonical JSON Schema for guest stdout (envelope list).
public enum PluginEnvelopeSchema {
    public static var jsonSchema: String {
        (try? GuestContract.loadSchemaText(.envelopeList))
            ?? fallbackSchema
    }

    private static let fallbackSchema = """
    {"title":"Guest stdout envelope list","type":"array"}
    """
}