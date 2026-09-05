import Foundation

public enum AgentRole: String, Codable, Sendable, Hashable {
    /// Interactive chat agent visible to the user.
    case userFacing = "user_facing"
    /// May spawn workers and join results (hierarchy v1).
    case coordinator
    /// Executes assigned tasks; silent to user by default.
    case worker
    /// Reserved for future specialized roles.
    case specialist
}

public enum AgentStatus: String, Codable, Sendable, Hashable {
    case created
    case running
    case idle
    case waiting
    case completed
    case failed
    case cancelled
}

/// Durable (or in-memory) description of an agent instance.
public struct AgentRecord: Hashable, Codable, Sendable, Identifiable {
    public var id: AgentRef { ref }

    public let ref: AgentRef
    public var role: AgentRole
    public var parentAgentID: String?
    public var status: AgentStatus
    /// Short role / goal overlay for system prompt composition.
    public var goal: String?
    public var systemOverlay: String?
    public var modelPreference: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var metadata: [String: String]

    public init(
        ref: AgentRef,
        role: AgentRole,
        parentAgentID: String? = nil,
        status: AgentStatus = .idle,
        goal: String? = nil,
        systemOverlay: String? = nil,
        modelPreference: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        metadata: [String: String] = [:]
    ) {
        self.ref = ref
        self.role = role
        self.parentAgentID = parentAgentID
        self.status = status
        self.goal = goal
        self.systemOverlay = systemOverlay
        self.modelPreference = modelPreference
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
    }

    public var depth: Int {
        // Depth is resolved by directory from parent chain; record only stores parent id.
        0
    }
}
