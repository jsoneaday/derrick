import Foundation

/// Process-wide log fan-out for SharedAgentRuntime (UI sink and/or stderr).
public final class RuntimeLog: @unchecked Sendable {
    public static let shared = RuntimeLog()

    private let lock = NSLock()
    private var sinks: [@Sendable (String) -> Void] = []

    private init() {}

    private var didAddUISink = false

    public func addSink(_ sink: @escaping @Sendable (String) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        sinks.append(sink)
    }

    /// SwiftUI may reconstruct `App`; only attach the UI recorder once.
    public func addUISinkOnce(_ sink: @escaping @Sendable (String) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !didAddUISink else { return }
        didAddUISink = true
        sinks.append(sink)
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
