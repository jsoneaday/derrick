import Foundation

public enum ServiceHealthStatus: String, Codable, Sendable, Hashable {
    case ok
    case degraded
    case starting
    case unavailable
}

/// Guest container images the product expects for offline plugin/script work.
public enum DerrickGuestRuntime: Sendable {
    /// Official Swift 6.4 image used by legacy factory and script execution.
    /// Swift 6.4 is not a stable Docker release yet; pin this tag to a digest
    /// when publishing a production build.
    public static let swiftPluginDockerImage = "swiftlang/swift:nightly-6.4.x-noble"

    /// Pullable Python image for offline guests (script_exec primary).
    public static let pythonGuestDockerImage = "python:3.14.7"

    /// Custom image with uv for packaged connector plugins.
    /// Build: `docker build -f docker/guest-runtime/Dockerfile -t derrick-guest-runtime:python-v1 .`
    public static let pythonGuestDockerImageWithUV = "derrick-guest-runtime:python-v1"
}

public struct ServiceHealthReport: Codable, Sendable, Hashable {
    public let service: DerrickServiceID
    public let status: ServiceHealthStatus
    public let protocolVersion: Int
    public let serviceVersion: String
    public let detail: String?
    public let pid: Int32
    public let checkedAt: Date
    /// Absent on older daemons. UI evicts the process when this is missing or mismatched.
    public let guestRuntimeImage: String?
    /// Fingerprint of the executable this process launched from. Absent on older daemons.
    public let executableFingerprint: String?

    public init(
        service: DerrickServiceID,
        status: ServiceHealthStatus,
        protocolVersion: Int = ServiceProtocolVersion.v1.rawValue,
        serviceVersion: String = "0.1.0",
        detail: String? = nil,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        checkedAt: Date = .now,
        guestRuntimeImage: String? = nil,
        executableFingerprint: String? = nil
    ) {
        self.service = service
        self.status = status
        self.protocolVersion = protocolVersion
        self.serviceVersion = serviceVersion
        self.detail = detail
        self.pid = pid
        self.checkedAt = checkedAt
        self.guestRuntimeImage = guestRuntimeImage
        self.executableFingerprint = executableFingerprint
    }
}
