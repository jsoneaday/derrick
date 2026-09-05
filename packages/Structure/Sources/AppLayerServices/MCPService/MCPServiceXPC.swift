import Foundation
import CryptoKit

/// XPC interface for MCPService (shared tool execution with principal).
@objc public protocol MCPServiceXPC {
    func health(withReply reply: @escaping @Sendable (NSData) -> Void)
    /// `payload` is signed `ServiceMessage` (type `ping`, payload `ServicePingDTO`). Reply signed ping.
    func ping(payload: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
    func bootstrap(withReply reply: @escaping @Sendable (NSData) -> Void)
    /// `authJSON` is signed `peerHandoff` / `fetchMCPPeer`. Endpoint travels via NSXPCCoder only.
    func peerListenerEndpoint(authJSON: NSData, withReply reply: @escaping @Sendable (NSXPCListenerEndpoint) -> Void)
    /// Docker helper peer endpoint + signed `installDockerHelperPeer` auth. Reply signed ack.
    func setDockerHelperPeerEndpoint(
        _ endpoint: NSXPCListenerEndpoint,
        authJSON: NSData,
        withReply reply: @escaping @Sendable (NSData) -> Void
    )
    /// Signed `runTool` envelope. Reply is `MCPToolCallResultDTO` (unsigned result body for now).
    func callTool(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
    /// Signed `searchTools` envelope. Reply is `MCPToolSearchResultDTO`.
    func searchTools(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
}

public struct MCPServiceBootstrapResult: Codable, Sendable, Hashable {
    public let ok: Bool
    public let databasePath: String?
    public let message: String

    public init(ok: Bool, databasePath: String? = nil, message: String) {
        self.ok = ok
        self.databasePath = databasePath
        self.message = message
    }
}

/// Tool invocation with mandatory principal (policy / audit).
public struct MCPToolCallRequest: Codable, Sendable, Hashable {
    public let requestID: String
    public let principal: ServicePrincipal
    public let toolName: String
    /// JSON object string of tool arguments (MCP Value map encoded as JSON object).
    public let argumentsJSON: String
    /// Conversation API key for in-MCPService helper LLM (script security reviewer).
    public let helperAPIKey: String?
    /// JSON `HelperModelWire` for script security reviewer model selection.
    /// When nil, MCPService uses the default helper model.
    public let helperReviewerModelJSON: String?
    /// When true, MCPService allows synchronous `web.crawl` (interactive `/create-plugin` turns).
    /// Deprecated: use `executionContextJSON` (ExecutionContextWire).
    public let pluginFactoryCreationActive: Bool
    /// JSON `ExecutionContextWire` for cross-boundary policy and effector admission.
    public let executionContextJSON: String?

    public init(
        requestID: String = UUID().uuidString,
        principal: ServicePrincipal,
        toolName: String,
        argumentsJSON: String,
        helperAPIKey: String? = nil,
        helperReviewerModelJSON: String? = nil,
        pluginFactoryCreationActive: Bool = false,
        executionContextJSON: String? = nil
    ) {
        self.requestID = requestID
        self.principal = principal
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.helperAPIKey = helperAPIKey
        self.helperReviewerModelJSON = helperReviewerModelJSON
        self.pluginFactoryCreationActive = pluginFactoryCreationActive
        self.executionContextJSON = executionContextJSON
    }
}

public struct MCPToolCallResultDTO: Codable, Sendable, Hashable {
    public let requestID: String
    public let ok: Bool
    public let isError: Bool
    public let text: String
    public let message: String

    public init(
        requestID: String,
        ok: Bool,
        isError: Bool = false,
        text: String = "",
        message: String = ""
    ) {
        self.requestID = requestID
        self.ok = ok
        self.isError = isError
        self.text = text
        self.message = message
    }
}

public struct MCPToolSearchRequest: Codable, Sendable, Hashable {
    public let principal: ServicePrincipal
    public let query: String

    public init(principal: ServicePrincipal, query: String = "") {
        self.principal = principal
        self.query = query
    }
}

public struct MCPToolDescriptorDTO: Codable, Sendable, Hashable {
    public let name: String
    public let description: String

    public init(name: String, description: String = "") {
        self.name = name
        self.description = description
    }
}

public struct MCPToolSearchResultDTO: Codable, Sendable, Hashable {
    public let ok: Bool
    public let tools: [MCPToolDescriptorDTO]
    public let message: String

    public init(ok: Bool, tools: [MCPToolDescriptorDTO] = [], message: String = "") {
        self.ok = ok
        self.tools = tools
        self.message = message
    }
}

public enum MCPServiceXPCCodec {
    public static func encodeHealth(_ report: ServiceHealthReport) throws -> Data {
        try JSONEncoder.service.encode(report)
    }

    public static func decodeHealth(_ data: Data) throws -> ServiceHealthReport {
        try JSONDecoder.service.decode(ServiceHealthReport.self, from: data)
    }

    public static func encodeBootstrap(_ result: MCPServiceBootstrapResult) throws -> Data {
        try JSONEncoder.service.encode(result)
    }

    public static func decodeBootstrap(_ data: Data) throws -> MCPServiceBootstrapResult {
        try JSONDecoder.service.decode(MCPServiceBootstrapResult.self, from: data)
    }

    public static func encodeToolCallRequest(_ request: MCPToolCallRequest) throws -> Data {
        try JSONEncoder.service.encode(request)
    }

    public static func decodeToolCallRequest(_ data: Data) throws -> MCPToolCallRequest {
        try JSONDecoder.service.decode(MCPToolCallRequest.self, from: data)
    }

    /// Signed envelope: Agent → MCP `runTool` (payload = `MCPToolCallRequest`).
    public static func encodeSignedToolCallRequest(
        _ request: MCPToolCallRequest,
        from: DerrickServiceID = .agent,
        key: SymmetricKey? = nil
    ) throws -> Data {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.encodeSignedDTO(
            request,
            from: from,
            to: .mcp,
            type: .runTool,
            principal: request.principal,
            correlationId: request.requestID,
            key: key
        )
    }

    public static func decodeSignedToolCallRequest(
        _ data: Data,
        key: SymmetricKey? = nil
    ) throws -> MCPToolCallRequest {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        let (_, dto) = try ServiceMessageEnvelope.decodeSignedDTO(
            data,
            as: MCPToolCallRequest.self,
            expectedType: .runTool,
            expectedTo: .mcp,
            key: key
        )
        return dto
    }

    public static func encodeToolCallResult(_ result: MCPToolCallResultDTO) throws -> Data {
        try JSONEncoder.service.encode(result)
    }

    public static func decodeToolCallResult(_ data: Data) throws -> MCPToolCallResultDTO {
        try JSONDecoder.service.decode(MCPToolCallResultDTO.self, from: data)
    }

    public static func encodeToolSearchRequest(_ request: MCPToolSearchRequest) throws -> Data {
        try JSONEncoder.service.encode(request)
    }

    public static func decodeToolSearchRequest(_ data: Data) throws -> MCPToolSearchRequest {
        try JSONDecoder.service.decode(MCPToolSearchRequest.self, from: data)
    }

    public static func encodeToolSearchResult(_ result: MCPToolSearchResultDTO) throws -> Data {
        try JSONEncoder.service.encode(result)
    }

    public static func decodeToolSearchResult(_ data: Data) throws -> MCPToolSearchResultDTO {
        try JSONDecoder.service.decode(MCPToolSearchResultDTO.self, from: data)
    }

    public static func encodeSignedToolSearchRequest(
        _ request: MCPToolSearchRequest,
        from: DerrickServiceID = .agent,
        key: SymmetricKey? = nil
    ) throws -> Data {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.encodeSignedDTO(
            request,
            from: from,
            to: .mcp,
            type: .searchTools,
            principal: request.principal,
            key: key
        )
    }

    public static func decodeSignedToolSearchRequest(
        _ data: Data,
        key: SymmetricKey? = nil
    ) throws -> MCPToolSearchRequest {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.decodeSignedDTO(
            data,
            as: MCPToolSearchRequest.self,
            expectedType: .searchTools,
            expectedTo: .mcp,
            key: key
        ).dto
    }

    public static func encodeSignedPing(
        _ text: String,
        from: DerrickServiceID,
        to: DerrickServiceID,
        key: SymmetricKey? = nil
    ) throws -> Data {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.encodeSignedDTO(
            ServicePingDTO(text: text),
            from: from,
            to: to,
            type: .ping,
            principal: .system,
            key: key
        )
    }

    public static func decodeSignedPing(
        _ data: Data,
        expectedTo: DerrickServiceID,
        key: SymmetricKey? = nil
    ) throws -> ServicePingDTO {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.decodeSignedDTO(
            data,
            as: ServicePingDTO.self,
            expectedType: .ping,
            expectedTo: expectedTo,
            key: key
        ).dto
    }

    public static func encodeSignedPeerHandoffAuth(
        _ auth: PeerHandoffAuthDTO,
        from: DerrickServiceID,
        to: DerrickServiceID,
        key: SymmetricKey? = nil
    ) throws -> Data {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.encodeSignedDTO(
            auth,
            from: from,
            to: to,
            type: .peerHandoff,
            principal: .system,
            correlationId: auth.kind.rawValue,
            key: key
        )
    }

    public static func decodeSignedPeerHandoffAuth(
        _ data: Data,
        expectedTo: DerrickServiceID,
        expectedKind: PeerHandoffAuthDTO.Kind,
        key: SymmetricKey? = nil
    ) throws -> PeerHandoffAuthDTO {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        let dto = try ServiceMessageEnvelope.decodeSignedDTO(
            data,
            as: PeerHandoffAuthDTO.self,
            expectedType: .peerHandoff,
            expectedTo: expectedTo,
            key: key
        ).dto
        guard dto.kind == expectedKind else {
            throw ServiceMessageEnvelope.Error.unexpectedType(
                expected: expectedKind.rawValue,
                got: dto.kind.rawValue
            )
        }
        return dto
    }

    public static func encodeSignedAck(
        _ ack: ServiceAckDTO,
        from: DerrickServiceID,
        to: DerrickServiceID,
        key: SymmetricKey? = nil
    ) throws -> Data {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.encodeAck(
            ack,
            from: from,
            to: to,
            type: .peerHandoff,
            key: key
        )
    }

    public static func decodeSignedAck(
        _ data: Data,
        expectedTo: DerrickServiceID,
        key: SymmetricKey? = nil
    ) throws -> ServiceAckDTO {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.decodeAck(
            data,
            expectedType: .peerHandoff,
            expectedTo: expectedTo,
            key: key
        )
    }

    public static func encodeString(_ string: String) -> Data {
        Data(string.utf8)
    }

    public static func decodeString(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }
}
