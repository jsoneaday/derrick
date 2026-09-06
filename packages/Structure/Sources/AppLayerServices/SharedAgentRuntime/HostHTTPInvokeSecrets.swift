import Structure

/// Task-local plugin secret scope for host HTTP during `plugin.invoke`.
///
/// Do not use process-wide mutable state for this — bootstrap, poll, and jobs can run concurrently.
public enum HostHTTPInvokeSecrets: Sendable {
    @TaskLocal public static var pluginID: String?
    @TaskLocal public static var secretFields: [PluginSecretDescriptor] = []

    public static func withValues<T>(
        pluginID: String,
        secretFields: [PluginSecretDescriptor],
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $pluginID.withValue(pluginID) {
            try await $secretFields.withValue(secretFields) {
                try await operation()
            }
        }
    }
}
