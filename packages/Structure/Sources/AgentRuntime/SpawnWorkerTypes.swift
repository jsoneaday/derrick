import Foundation

public struct SpawnWorkerRequest: Sendable, Hashable {
    public let parent: AgentRef
    public let goal: String
    public let task: String
    public let agentID: String?

    public init(parent: AgentRef, goal: String, task: String, agentID: String? = nil) {
        self.parent = parent
        self.goal = goal
        self.task = task
        self.agentID = agentID
    }
}

public struct SpawnWorkerResult: Sendable, Hashable {
    public let child: AgentRef
    public let result: String
    public let status: AgentStatus

    public init(child: AgentRef, result: String, status: AgentStatus) {
        self.child = child
        self.result = result
        self.status = status
    }
}
