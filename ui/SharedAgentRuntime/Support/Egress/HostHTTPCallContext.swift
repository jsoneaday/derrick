import Foundation
import Structure

/// Process-wide slot for the current host-HTTP invoke (TaskLocal does not cross MCP handlers).
public final class HostHTTPCallContext: @unchecked Sendable {
    public static let shared = HostHTTPCallContext()

    private let lock = NSLock()
    private var _jobID: String?
    private var _pluginID: String?
    private var _secretFields: [PluginSecretDescriptor] = []

    private init() {}

    public func install(
        jobID: String?,
        pluginID: String? = nil,
        secretFields: [PluginSecretDescriptor] = []
    ) {
        lock.lock()
        _jobID = jobID
        _pluginID = pluginID
        _secretFields = secretFields
        lock.unlock()
    }

    public func setPluginSecrets(pluginID: String, fields: [PluginSecretDescriptor]) {
        lock.lock()
        _pluginID = pluginID
        _secretFields = fields
        lock.unlock()
    }

    public func clear() {
        lock.lock()
        _jobID = nil
        _pluginID = nil
        _secretFields = []
        lock.unlock()
    }

    public var jobID: String? {
        lock.lock()
        defer { lock.unlock() }
        return _jobID
    }

    public var pluginID: String? {
        lock.lock()
        defer { lock.unlock() }
        return _pluginID
    }

    public var secretFields: [PluginSecretDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        return _secretFields
    }
}
