import Foundation
import ServiceContracts

/// Canonical JSON Schema for standalone Swift program stdout.
public enum PluginEnvelopeSchema {
    public static var jsonSchema: String {
        DerrickBundledText.registerSearchRoot(Bundle.module.resourceURL ?? Bundle.module.bundleURL)
        return DerrickBundledText.mustLoad("guest/handle-return.schema.json")
    }
}
