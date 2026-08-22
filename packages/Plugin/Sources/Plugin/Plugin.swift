/// Contract types for sandboxed Swift programs and Agent Plugin packages.
/// This module does not execute guest code and does not talk XPC.
public enum PluginContract {
    public static let envelopeSchemaVersion = 1
    public static let uiSchemaVersion = 1
    public static let maxHops = 8

    public static let agentPluginSchema = "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json"
    public static let derrickExtensionNamespace = "app.derrick"
    public static let minScheduleIntervalSeconds = 60
    public static let defaultVolumeQuotaBytes = 268_435_456
    public static let defaultHTTPCallsPerInvoke = 20
    public static let defaultHTTPJSONBytes = 1_048_576
    public static let defaultHTTPFileBytes = 10_485_760
    public static let defaultTimeoutSeconds = 60
}
