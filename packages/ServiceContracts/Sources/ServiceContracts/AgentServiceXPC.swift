import Foundation

/// XPC interface for AgentService.
@objc public protocol AgentServiceXPC {
    func health(withReply reply: @escaping @Sendable (NSData) -> Void)
    /// Echo for connectivity tests. `payload` is UTF-8 text.
    func ping(payload: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
    /// Bootstrap shared DB + service_logs. Safe to call repeatedly.
    func bootstrap(withReply reply: @escaping @Sendable (NSData) -> Void)
    /// Start a conversation turn. Chunks stream via `AgentServiceClientSinkXPC`.
    /// `requestJSON` is `AgentTurnRequest`. Reply is `AgentTurnAccepted`.
    func startTurn(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
    /// Cancel an in-flight turn.
    func cancelTurn(turnID: String, withReply reply: @escaping @Sendable (NSData) -> Void)
}

/// Reverse channel: UI exports this on the XPC connection for turn streaming / approvals / log relay.
/// Note: avoid optional NSData parameters — they bridge poorly over NSXPC.
@objc public protocol AgentServiceClientSinkXPC {
    func appendServiceLogLine(_ line: String)
    func turnDidEmitChunk(_ turnID: String, chunkJSON: NSData)
    /// `errorJSON` empty means success; otherwise encoded `AgentTurnErrorDTO`.
    func turnDidFinish(_ turnID: String, errorJSON: NSData)
    /// Ask the UI to present an approval modal. `requestJSON` is `AgentApprovalRequestDTO`.
    /// Reply payload is `AgentApprovalDecisionDTO` (always non-empty JSON).
    func requestApproval(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
    /// Ask the UI to allow a network host (egress preflight / mid-flight).
    /// `requestJSON` is `AgentNetworkAccessRequestDTO`; reply is `AgentNetworkAccessDecisionDTO`.
    func requestNetworkAccess(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
}

/// Result of AgentService bootstrap.
public struct AgentServiceBootstrapResult: Codable, Sendable, Hashable {
    public let ok: Bool
    public let databasePath: String?
    public let message: String

    public init(ok: Bool, databasePath: String? = nil, message: String) {
        self.ok = ok
        self.databasePath = databasePath
        self.message = message
    }
}

public enum AgentServiceXPCCodec {
    public static func encodeHealth(_ report: ServiceHealthReport) throws -> Data {
        try JSONEncoder.service.encode(report)
    }

    public static func decodeHealth(_ data: Data) throws -> ServiceHealthReport {
        try JSONDecoder.service.decode(ServiceHealthReport.self, from: data)
    }

    public static func encodeBootstrap(_ result: AgentServiceBootstrapResult) throws -> Data {
        try JSONEncoder.service.encode(result)
    }

    public static func decodeBootstrap(_ data: Data) throws -> AgentServiceBootstrapResult {
        try JSONDecoder.service.decode(AgentServiceBootstrapResult.self, from: data)
    }

    public static func encodeTurnRequest(_ request: AgentTurnRequest) throws -> Data {
        try JSONEncoder.service.encode(request)
    }

    public static func decodeTurnRequest(_ data: Data) throws -> AgentTurnRequest {
        try JSONDecoder.service.decode(AgentTurnRequest.self, from: data)
    }

    public static func encodeTurnAccepted(_ accepted: AgentTurnAccepted) throws -> Data {
        try JSONEncoder.service.encode(accepted)
    }

    public static func decodeTurnAccepted(_ data: Data) throws -> AgentTurnAccepted {
        try JSONDecoder.service.decode(AgentTurnAccepted.self, from: data)
    }

    public static func encodeTurnChunk(_ chunk: AgentTurnChunkDTO) throws -> Data {
        try JSONEncoder.service.encode(chunk)
    }

    public static func decodeTurnChunk(_ data: Data) throws -> AgentTurnChunkDTO {
        try JSONDecoder.service.decode(AgentTurnChunkDTO.self, from: data)
    }

    public static func encodeTurnError(_ error: AgentTurnErrorDTO) throws -> Data {
        try JSONEncoder.service.encode(error)
    }

    public static func decodeTurnError(_ data: Data) throws -> AgentTurnErrorDTO {
        try JSONDecoder.service.decode(AgentTurnErrorDTO.self, from: data)
    }

    public static func encodeApprovalRequest(_ request: AgentApprovalRequestDTO) throws -> Data {
        try JSONEncoder.service.encode(request)
    }

    public static func decodeApprovalRequest(_ data: Data) throws -> AgentApprovalRequestDTO {
        try JSONDecoder.service.decode(AgentApprovalRequestDTO.self, from: data)
    }

    public static func encodeApprovalDecision(_ decision: AgentApprovalDecisionDTO) throws -> Data {
        try JSONEncoder.service.encode(decision)
    }

    public static func decodeApprovalDecision(_ data: Data) throws -> AgentApprovalDecisionDTO {
        try JSONDecoder.service.decode(AgentApprovalDecisionDTO.self, from: data)
    }

    public static func encodeNetworkAccessRequest(_ request: AgentNetworkAccessRequestDTO) throws -> Data {
        try JSONEncoder.service.encode(request)
    }

    public static func decodeNetworkAccessRequest(_ data: Data) throws -> AgentNetworkAccessRequestDTO {
        try JSONDecoder.service.decode(AgentNetworkAccessRequestDTO.self, from: data)
    }

    public static func encodeNetworkAccessDecision(_ decision: AgentNetworkAccessDecisionDTO) throws -> Data {
        try JSONEncoder.service.encode(decision)
    }

    public static func decodeNetworkAccessDecision(_ data: Data) throws -> AgentNetworkAccessDecisionDTO {
        try JSONDecoder.service.decode(AgentNetworkAccessDecisionDTO.self, from: data)
    }

    public static func encodeString(_ string: String) -> Data {
        Data(string.utf8)
    }

    public static func decodeString(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }
}

public extension JSONEncoder {
    static var service: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

public extension JSONDecoder {
    static var service: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
