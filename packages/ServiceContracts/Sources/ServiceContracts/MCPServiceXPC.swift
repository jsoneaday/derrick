import Foundation

/// XPC interface for MCPService (shared tool execution with principal).
@objc public protocol MCPServiceXPC {
    func health(withReply reply: @escaping @Sendable (NSData) -> Void)
    func ping(payload: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
    func bootstrap(withReply reply: @escaping @Sendable (NSData) -> Void)
    /// Anonymous peer listener endpoint for sibling services (AgentService).
    /// Must travel over XPC (`NSXPCCoder`); cannot be NSKeyedArchived to disk.
    func peerListenerEndpoint(withReply reply: @escaping @Sendable (NSXPCListenerEndpoint) -> Void)
    /// `requestJSON` is `MCPToolCallRequest`. Reply is `MCPToolCallResultDTO`.
    func callTool(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
    /// `queryJSON` is `MCPToolSearchRequest`. Reply is `MCPToolSearchResultDTO`.
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

    public init(
        requestID: String = UUID().uuidString,
        principal: ServicePrincipal,
        toolName: String,
        argumentsJSON: String
    ) {
        self.requestID = requestID
        self.principal = principal
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
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

    public static func encodeString(_ string: String) -> Data {
        Data(string.utf8)
    }

    public static func decodeString(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }
}
