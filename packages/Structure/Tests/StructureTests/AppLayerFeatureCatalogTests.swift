import Foundation
import Structure
import Testing

@Suite struct AppLayerFeatureCatalogTests {
    @Test func everyFeatureListsStructureContracts() {
        #expect(AppLayerFeatureCatalog.contracts.count == AppLayerFeature.allCases.count)
        for feature in AppLayerFeature.allCases {
            let contract = AppLayerFeatureCatalog.contract(for: feature)
            #expect(!contract.structureTypeNames.isEmpty)
        }
    }

    @Test func agentProfilesAndManifestsUseCatalogProtocols() {
        let profiles = AppLayerFeatureCatalog.contract(for: .agentProfiles)
        #expect(profiles.structureTypeNames.contains("AgentProfileCatalog"))
        #expect(profiles.uiMustNotImportMCPServer)
        let manifests = AppLayerFeatureCatalog.contract(for: .pluginFactoryManifests)
        #expect(manifests.structureTypeNames.contains("PluginFactoryManifestCatalog"))
    }

    @Test func hostHTTPSecretAttacherLivesInStructure() async {
        struct PassThrough: HostHTTPSecretAttacher {
            func apply(url: URL) async -> (url: URL, headers: [String: String]) {
                (url, [:])
            }
        }
        let url = URL(string: "https://example.com")!
        let attached = await PassThrough().apply(url: url)
        #expect(attached.url == url)
        #expect(attached.headers.isEmpty)
    }

    @Test func inMemoryAgentProfileCatalogSatisfiesProtocol() async throws {
        let catalog = MemoryAgentProfileCatalog()
        let profile = AgentProfile.orchestratorDefault(modelJSON: Data(#"{"openai":"gpt-5.6-luna"}"#.utf8))
        try await catalog.upsertAgentProfile(profile)
        #expect(try await catalog.listAgentProfiles().count == 1)
        #expect(try await catalog.agentProfile(handle: "orchestrator")?.id == profile.id)
        try await catalog.deleteAgentProfile(id: profile.id)
        #expect(try await catalog.listAgentProfiles().isEmpty)
    }

    @Test func pluginCredentialGroupDisplayNameIsHumanReadable() {
        let group = PluginCredentialGroup(
            pluginID: "slack-connection",
            isConnector: true,
            secrets: [PluginSecretDescriptor(id: "bot_token", label: "Bot Token", kind: "token")]
        )
        #expect(group.displayName == "Slack Connection")
    }
}

actor MemoryAgentProfileCatalog: AgentProfileCatalog {
    private var profiles: [String: AgentProfile] = [:]

    func upsertAgentProfile(_ profile: AgentProfile) throws {
        profiles[profile.id] = profile
    }

    func listAgentProfiles() throws -> [AgentProfile] {
        profiles.values.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder {
                return lhs.sortOrder < rhs.sortOrder
            }
            return lhs.displayName < rhs.displayName
        }
    }

    func agentProfile(id: String) throws -> AgentProfile? {
        profiles[id]
    }

    func agentProfile(handle: String) throws -> AgentProfile? {
        let normalized = handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return profiles.values.first { $0.handle == normalized }
    }

    func deleteAgentProfile(id: String) throws {
        profiles.removeValue(forKey: id)
    }
}
