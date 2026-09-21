import Foundation

/// Persistence for agent profiles. UI and AppLayer take this protocol, not SQLite.
public protocol AgentProfileCatalog: Actor {
    func upsertAgentProfile(_ profile: AgentProfile) throws
    func listAgentProfiles() throws -> [AgentProfile]
    func agentProfile(id: String) throws -> AgentProfile?
    func agentProfile(handle: String) throws -> AgentProfile?
    func deleteAgentProfile(id: String) throws
}
