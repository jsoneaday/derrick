import Foundation

/// Control surface for the headless Derrick daemon (`derrick.ui.Daemon`).
@objc public protocol DerrickDaemonXPC {
    func health(withReply reply: @escaping @Sendable (NSData) -> Void)
    func bootstrap(withReply reply: @escaping @Sendable (NSData) -> Void)
    /// Encoded `UserNotificationRequest`. Reply encoded `ServiceAckDTO`.
    func postUserNotification(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
}

/// Full daemon surface: control + in-process Agent / Job / MCP methods on one Mach connection.
@objc public protocol DerrickDaemonServiceXPC: DerrickDaemonXPC, AgentServiceXPC, JobServiceXPC, MCPServiceXPC {}

public struct DerrickDaemonBootstrapResult: Codable, Sendable, Hashable {
    public let ok: Bool
    public let databasePath: String?
    public let pid: Int32
    public let message: String
    public let modules: [String]

    public init(
        ok: Bool,
        databasePath: String? = nil,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        message: String,
        modules: [String] = []
    ) {
        self.ok = ok
        self.databasePath = databasePath
        self.pid = pid
        self.message = message
        self.modules = modules
    }
}

public enum DerrickDaemonXPCCodec {
    public static func encodeHealth(_ report: ServiceHealthReport) throws -> Data {
        try JSONEncoder.service.encode(report)
    }

    public static func decodeHealth(_ data: Data) throws -> ServiceHealthReport {
        try JSONDecoder.service.decode(ServiceHealthReport.self, from: data)
    }

    public static func encodeBootstrap(_ result: DerrickDaemonBootstrapResult) throws -> Data {
        try JSONEncoder.service.encode(result)
    }

    public static func decodeBootstrap(_ data: Data) throws -> DerrickDaemonBootstrapResult {
        try JSONDecoder.service.decode(DerrickDaemonBootstrapResult.self, from: data)
    }

    public static func encodeNotificationRequest(_ request: UserNotificationRequest) throws -> Data {
        try JSONEncoder.service.encode(request)
    }

    public static func decodeNotificationRequest(_ data: Data) throws -> UserNotificationRequest {
        try JSONDecoder.service.decode(UserNotificationRequest.self, from: data)
    }

    public static func encodeAck(_ ack: ServiceAckDTO) throws -> Data {
        try JSONEncoder.service.encode(ack)
    }

    public static func decodeAck(_ data: Data) throws -> ServiceAckDTO {
        try JSONDecoder.service.decode(ServiceAckDTO.self, from: data)
    }
}
