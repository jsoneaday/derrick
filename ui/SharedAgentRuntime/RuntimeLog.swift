import Foundation

/// Process-wide log fan-out for SharedAgentRuntime (UI sink and/or stderr).
public final class RuntimeLog: @unchecked Sendable {
    public static let shared = RuntimeLog()

    private let lock = NSLock()
    private var sinks: [@Sendable (String) -> Void] = []

    private init() {}

    public func addSink(_ sink: @escaping @Sendable (String) -> Void) {
        lock.lock()
        sinks.append(sink)
        lock.unlock()
    }

    public func emit(_ message: String) {
        fputs("[AgentRuntime] \(message)\n", stderr)
        lock.lock()
        let copy = sinks
        lock.unlock()
        for sink in copy {
            sink(message)
        }
    }
}

nonisolated func debugLog(_ message: String) {
    RuntimeLog.shared.emit(message)
}
