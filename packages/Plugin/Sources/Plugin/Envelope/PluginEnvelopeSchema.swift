import Foundation
import ServiceContracts

/// Canonical JSON Schema for `handle()` stdout. Loaded from SharedAgentRuntime Resources.
public enum PluginEnvelopeSchema {
    public static var jsonSchema: String {
        DerrickGuestTypeScript.registerPluginResourceBundle()
        return DerrickBundledText.mustLoad("guest/handle-return.schema.json")
    }
}
