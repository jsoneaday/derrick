import Foundation

/// Maps worker-image / Docker tool failures into short user copy.
/// Logs should keep the raw error; this is only for people reading the chat.
public enum WorkerImageFailureDisplay: Sendable {
    public static let toolsNotReady =
        "Derrick could not use its web tools just now. Keep Docker Desktop open and try again in a moment."
    public static let runtimeNotReady =
        "Derrick could not run this plugin just now. Keep Docker Desktop open and try again in a moment."

    public static func isWorkerImageIssue(_ raw: String) -> Bool {
        let lowered = raw.lowercased()
        let indicators = [
            "does not match the version shipped",
            "rebuild or reinstall product images",
            "worker image",
            "search image is not installed",
            "crawler image is not installed",
            "derrick-worker:",
            "could not build the worker image",
            "could not prepare its web tools",
            "could not use its web tools",
            "web tools were not ready",
            "docker flag is not allowed",
            "xpc validation",
            "create search container",
            "create crawler container",
            "could not find its source to build",
            "could not find its build files",
        ]
        return indicators.contains { lowered.contains($0) }
    }

    public static func userFacing(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return toolsNotReady }
        if isWorkerImageIssue(trimmed) {
            if trimmed.lowercased().contains("plugin")
                || trimmed.lowercased().contains("guest")
                || trimmed.lowercased().contains("does not match the version shipped") {
                return runtimeNotReady
            }
            return toolsNotReady
        }
        return trimmed
    }
}
