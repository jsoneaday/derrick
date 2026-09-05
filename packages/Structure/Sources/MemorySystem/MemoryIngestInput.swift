import Foundation

public struct MemoryIngestInput: Hashable, Codable, Sendable {
    public let sessionKey: MemorySessionKey
    public let parentAgentID: String?
    public let prompt: String
    public let completion: String
    public let toolCalls: [ToolCallRecord]
    public let scope: MemoryAccessibility

    public init(
        sessionKey: MemorySessionKey,
        parentAgentID: String? = nil,
        prompt: String,
        completion: String,
        toolCalls: [ToolCallRecord] = [],
        scope: MemoryAccessibility = .private
    ) {
        self.sessionKey = sessionKey
        self.parentAgentID = parentAgentID
        self.prompt = prompt
        self.completion = completion
        self.toolCalls = toolCalls
        self.scope = scope
    }
}
