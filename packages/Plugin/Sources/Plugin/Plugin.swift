/// Contract types for sandboxed Bun scripts and (later) plugins.
/// This module does not execute guest code and does not talk XPC.
public enum PluginContract {
    public static let envelopeSchemaVersion = 1
    public static let uiSchemaVersion = 1
    public static let maxHops = 8
}
