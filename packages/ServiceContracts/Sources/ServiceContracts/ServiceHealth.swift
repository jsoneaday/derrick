import Foundation

public enum ServiceHealthStatus: String, Codable, Sendable, Hashable {
    case ok
    case degraded
    case starting
    case unavailable
}

/// Swift guest container image the current product expects the daemon to use.
public enum DerrickGuestRuntime: Sendable {
    /// Official Swift 6.4 image used by factory and script execution.
    /// Swift 6.4 is not a stable Docker release yet; pin this tag to a digest
    /// when publishing a production build.
    public static let swiftPluginDockerImage = "swiftlang/swift:nightly-6.4.x-noble"
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
