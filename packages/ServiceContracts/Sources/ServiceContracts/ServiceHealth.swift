import Foundation

public enum ServiceHealthStatus: String, Codable, Sendable, Hashable {
    case ok
    case degraded
    case starting
    case unavailable
}

public struct ServiceHealthReport: Codable, Sendable, Hashable {
    public let service: DerrickServiceID
    public let status: ServiceHealthStatus
    public let protocolVersion: Int
    public let serviceVersion: String
    public let detail: String?
    public let pid: Int32
    public let checkedAt: Date

    public init(
        service: DerrickServiceID,
        status: ServiceHealthStatus,
        protocolVersion: Int = ServiceProtocolVersion.v1.rawValue,
        serviceVersion: String = "0.1.0",
        detail: String? = nil,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        checkedAt: Date = .now
    ) {
        self.service = service
        self.status = status
        self.protocolVersion = protocolVersion
        self.serviceVersion = serviceVersion
        self.detail = detail
        self.pid = pid
        self.checkedAt = checkedAt
    }
}
