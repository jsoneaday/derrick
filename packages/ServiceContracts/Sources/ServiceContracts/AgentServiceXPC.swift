import Foundation
import CryptoKit

/// XPC interface for AgentService.
@objc public protocol AgentServiceXPC {
    func health(withReply reply: @escaping @Sendable (NSData) -> Void)
    /// Signed `ping` envelope. Reply signed ping.
    func ping(payload: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
    /// Bootstrap shared DB + service_logs. Safe to call repeatedly. (unsigned)
    func bootstrap(withReply reply: @escaping @Sendable (NSData) -> Void)
    /// MCP peer endpoint + signed `installMCPPeer` auth. Reply signed ack.
    func setMCPServicePeerEndpoint(
        _ endpoint: NSXPCListenerEndpoint,
        authJSON: NSData,
        withReply reply: @escaping @Sendable (NSData) -> Void
    )
    /// Signed `injectUserMessage`. Reply is `AgentTurnAccepted`.
    func startTurn(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
    /// Signed `cancelTurn` (payload `CancelTurnRequestDTO`). Reply signed ack.
    func cancelTurn(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
}

/// Reverse channel: UI exports this on the XPC connection for turn streaming / approvals / log relay.
/// Note: avoid optional NSData parameters — they bridge poorly over NSXPC.
@objc public protocol AgentServiceClientSinkXPC {
    func appendServiceLogLine(_ line: String)
    func turnDidEmitChunk(_ turnID: String, chunkJSON: NSData)
    /// `errorJSON` empty means success; otherwise encoded `AgentTurnErrorDTO`.
    func turnDidFinish(_ turnID: String, errorJSON: NSData)
    /// Signed `approvalRequest` → reply signed `approvalDecision`.
    func requestApproval(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
    /// Signed `networkAccessRequest` → reply signed `networkAccessDecision`.
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

    /// Signed envelope: UI → Agent `injectUserMessage` (payload = `AgentTurnRequest`).
    public static func encodeSignedTurnRequest(
        _ request: AgentTurnRequest,
        key: SymmetricKey? = nil
    ) throws -> Data {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.encodeSignedDTO(
            request,
            from: .ui,
            to: .agent,
            type: .injectUserMessage,
            principal: .ui,
            correlationId: request.turnID,
            key: key
        )
    }

    public static func decodeSignedTurnRequest(
        _ data: Data,
        key: SymmetricKey? = nil
    ) throws -> AgentTurnRequest {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        let (_, dto) = try ServiceMessageEnvelope.decodeSignedDTO(
            data,
            as: AgentTurnRequest.self,
            expectedType: .injectUserMessage,
            expectedTo: .agent,
            key: key
        )
        return dto
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

    public static func encodeSignedApprovalRequest(
        _ request: AgentApprovalRequestDTO,
        key: SymmetricKey? = nil
    ) throws -> Data {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.encodeSignedDTO(
            request,
            from: .agent,
            to: .ui,
            type: .approvalRequest,
            principal: .system,
            correlationId: request.approvalID,
            key: key
        )
    }

    public static func decodeSignedApprovalRequest(
        _ data: Data,
        key: SymmetricKey? = nil
    ) throws -> AgentApprovalRequestDTO {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.decodeSignedDTO(
            data,
            as: AgentApprovalRequestDTO.self,
            expectedType: .approvalRequest,
            expectedTo: .ui,
            key: key
        ).dto
    }

    public static func encodeApprovalDecision(_ decision: AgentApprovalDecisionDTO) throws -> Data {
        try JSONEncoder.service.encode(decision)
    }

    public static func decodeApprovalDecision(_ data: Data) throws -> AgentApprovalDecisionDTO {
        try JSONDecoder.service.decode(AgentApprovalDecisionDTO.self, from: data)
    }

    public static func encodeSignedApprovalDecision(
        _ decision: AgentApprovalDecisionDTO,
        key: SymmetricKey? = nil
    ) throws -> Data {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.encodeSignedDTO(
            decision,
            from: .ui,
            to: .agent,
            type: .approvalDecision,
            principal: .ui,
            correlationId: decision.approvalID,
            key: key
        )
    }

    public static func decodeSignedApprovalDecision(
        _ data: Data,
        key: SymmetricKey? = nil
    ) throws -> AgentApprovalDecisionDTO {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.decodeSignedDTO(
            data,
            as: AgentApprovalDecisionDTO.self,
            expectedType: .approvalDecision,
            expectedTo: .agent,
            key: key
        ).dto
    }

    public static func encodeNetworkAccessRequest(_ request: AgentNetworkAccessRequestDTO) throws -> Data {
        try JSONEncoder.service.encode(request)
    }

    public static func decodeNetworkAccessRequest(_ data: Data) throws -> AgentNetworkAccessRequestDTO {
        try JSONDecoder.service.decode(AgentNetworkAccessRequestDTO.self, from: data)
    }

    public static func encodeSignedNetworkAccessRequest(
        _ request: AgentNetworkAccessRequestDTO,
        key: SymmetricKey? = nil
    ) throws -> Data {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.encodeSignedDTO(
            request,
            from: .agent,
            to: .ui,
            type: .networkAccessRequest,
            principal: .system,
            correlationId: request.requestID,
            key: key
        )
    }

    public static func decodeSignedNetworkAccessRequest(
        _ data: Data,
        key: SymmetricKey? = nil
    ) throws -> AgentNetworkAccessRequestDTO {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.decodeSignedDTO(
            data,
            as: AgentNetworkAccessRequestDTO.self,
            expectedType: .networkAccessRequest,
            expectedTo: .ui,
            key: key
        ).dto
    }

    public static func encodeNetworkAccessDecision(_ decision: AgentNetworkAccessDecisionDTO) throws -> Data {
        try JSONEncoder.service.encode(decision)
    }

    public static func decodeNetworkAccessDecision(_ data: Data) throws -> AgentNetworkAccessDecisionDTO {
        try JSONDecoder.service.decode(AgentNetworkAccessDecisionDTO.self, from: data)
    }

    public static func encodeSignedNetworkAccessDecision(
        _ decision: AgentNetworkAccessDecisionDTO,
        key: SymmetricKey? = nil
    ) throws -> Data {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.encodeSignedDTO(
            decision,
            from: .ui,
            to: .agent,
            type: .networkAccessDecision,
            principal: .ui,
            correlationId: decision.requestID,
            key: key
        )
    }

    public static func decodeSignedNetworkAccessDecision(
        _ data: Data,
        key: SymmetricKey? = nil
    ) throws -> AgentNetworkAccessDecisionDTO {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.decodeSignedDTO(
            data,
            as: AgentNetworkAccessDecisionDTO.self,
            expectedType: .networkAccessDecision,
            expectedTo: .agent,
            key: key
        ).dto
    }

    public static func encodeSignedCancelTurn(
        turnID: String,
        key: SymmetricKey? = nil
    ) throws -> Data {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.encodeSignedDTO(
            CancelTurnRequestDTO(turnID: turnID),
            from: .ui,
            to: .agent,
            type: .cancelTurn,
            principal: .ui,
            correlationId: turnID,
            key: key
        )
    }

    public static func decodeSignedCancelTurn(
        _ data: Data,
        key: SymmetricKey? = nil
    ) throws -> CancelTurnRequestDTO {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.decodeSignedDTO(
            data,
            as: CancelTurnRequestDTO.self,
            expectedType: .cancelTurn,
            expectedTo: .agent,
            key: key
        ).dto
    }

    public static func encodeSignedPeerHandoffAuth(
        _ auth: PeerHandoffAuthDTO,
        from: DerrickServiceID,
        to: DerrickServiceID,
        key: SymmetricKey? = nil
    ) throws -> Data {
        try MCPServiceXPCCodec.encodeSignedPeerHandoffAuth(auth, from: from, to: to, key: key)
    }

    public static func decodeSignedPeerHandoffAuth(
        _ data: Data,
        expectedTo: DerrickServiceID,
        expectedKind: PeerHandoffAuthDTO.Kind,
        key: SymmetricKey? = nil
    ) throws -> PeerHandoffAuthDTO {
        try MCPServiceXPCCodec.decodeSignedPeerHandoffAuth(
            data,
            expectedTo: expectedTo,
            expectedKind: expectedKind,
            key: key
        )
    }

    public static func encodeSignedAck(
        _ ack: ServiceAckDTO,
        from: DerrickServiceID,
        to: DerrickServiceID,
        key: SymmetricKey? = nil
    ) throws -> Data {
        try MCPServiceXPCCodec.encodeSignedAck(ack, from: from, to: to, key: key)
    }

    public static func decodeSignedAck(
        _ data: Data,
        expectedTo: DerrickServiceID,
        key: SymmetricKey? = nil
    ) throws -> ServiceAckDTO {
        try MCPServiceXPCCodec.decodeSignedAck(data, expectedTo: expectedTo, key: key)
    }

    public static func encodeSignedPing(
        _ text: String,
        from: DerrickServiceID,
        to: DerrickServiceID,
        key: SymmetricKey? = nil
    ) throws -> Data {
        try MCPServiceXPCCodec.encodeSignedPing(text, from: from, to: to, key: key)
    }

    public static func decodeSignedPing(
        _ data: Data,
        expectedTo: DerrickServiceID,
        key: SymmetricKey? = nil
    ) throws -> ServicePingDTO {
        try MCPServiceXPCCodec.decodeSignedPing(data, expectedTo: expectedTo, key: key)
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
