import Foundation

/// Process-wide slot for the current host-HTTP invoke (TaskLocal does not cross MCP handlers).
public final class HostHTTPCallContext: @unchecked Sendable {
    public static let shared = HostHTTPCallContext()

    private let lock = NSLock()
    private var _jobID: String?

    private init() {}

    public func install(jobID: String?) {
        lock.lock()
        _jobID = jobID
        lock.unlock()
    }

    public func clear() {
        lock.lock()
        _jobID = nil
        lock.unlock()
    }

    public var jobID: String? {
        lock.lock()
        defer { lock.unlock() }
        return _jobID
    }
}
