import Foundation

/// Control surface for the headless Derrick daemon (`derrick.ui.Daemon`).
@objc public protocol DerrickDaemonXPC {
    func health(withReply reply: @escaping @Sendable (NSData) -> Void)
    func bootstrap(withReply reply: @escaping @Sendable (NSData) -> Void)
    /// Encoded `UserNotificationRequest`. Reply encoded `ServiceAckDTO`.
    func postUserNotification(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
    /// Ask this process to exit so launchd KeepAlive re-execs the on-disk binary. Reply `ServiceAckDTO`.
    func retire(withReply reply: @escaping @Sendable (NSData) -> Void)
    /// Soft egress blacklist. Reply `EgressBlacklistListResult`.
    func listEgressBlacklist(withReply reply: @escaping @Sendable (NSData) -> Void)
    /// Add `host` or `*.domain`. Request `EgressBlacklistAddRequest`. Reply `ServiceAckDTO`.
    func addEgressBlacklist(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
    /// Remove by id. Request `EgressBlacklistRemoveRequest`. Reply `ServiceAckDTO`.
    func removeEgressBlacklist(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
}

/// Full daemon surface: control + in-process Agent / Job / MCP / Workflow methods on one Mach connection.
@objc public protocol DerrickDaemonServiceXPC: DerrickDaemonXPC, AgentServiceXPC, JobServiceXPC, MCPServiceXPC, WorkflowRuntimeXPC, ConnectorMessagingXPC {}

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

    public static func encodeBlacklistList(_ result: EgressBlacklistListResult) throws -> Data {
        try JSONEncoder.service.encode(result)
    }

    public static func decodeBlacklistList(_ data: Data) throws -> EgressBlacklistListResult {
        try JSONDecoder.service.decode(EgressBlacklistListResult.self, from: data)
    }

    public static func encodeBlacklistAddRequest(_ request: EgressBlacklistAddRequest) throws -> Data {
        try JSONEncoder.service.encode(request)
    }

    public static func decodeBlacklistAddRequest(_ data: Data) throws -> EgressBlacklistAddRequest {
        try JSONDecoder.service.decode(EgressBlacklistAddRequest.self, from: data)
    }

    public static func encodeBlacklistRemoveRequest(_ request: EgressBlacklistRemoveRequest) throws -> Data {
        try JSONEncoder.service.encode(request)
    }

    public static func decodeBlacklistRemoveRequest(_ data: Data) throws -> EgressBlacklistRemoveRequest {
        try JSONDecoder.service.decode(EgressBlacklistRemoveRequest.self, from: data)
    }
}
