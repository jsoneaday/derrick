import Foundation

/// Major product surfaces that must be driven from Structure contracts.
/// Persistence may still be SQLite; UI must not invent parallel DTOs or skip these types.
public enum AppLayerFeature: String, CaseIterable, Sendable {
    case agentProfiles
    case pluginCredentials
    case pluginFactoryManifests
    case hostHTTPSecrets
    case scriptReview
    case mcpToolCatalog
    case conversationMCPBridge
}

public struct AppLayerFeatureContract: Sendable, Hashable {
    public let feature: AppLayerFeature
    /// Type names that live in Structure and that this feature must use.
    public let structureTypeNames: [String]
    /// SQLite is an allowed implementation of Structure catalogs.
    public let persistenceMayBeSQLite: Bool
    /// When true, UI files for this feature must not import MCPServer.
    public let uiMustNotImportMCPServer: Bool

    public init(
        feature: AppLayerFeature,
        structureTypeNames: [String],
        persistenceMayBeSQLite: Bool,
        uiMustNotImportMCPServer: Bool
    ) {
        self.feature = feature
        self.structureTypeNames = structureTypeNames
        self.persistenceMayBeSQLite = persistenceMayBeSQLite
        self.uiMustNotImportMCPServer = uiMustNotImportMCPServer
    }
}

public enum AppLayerFeatureCatalog {
    public static let contracts: [AppLayerFeatureContract] = [
        AppLayerFeatureContract(
            feature: .agentProfiles,
            structureTypeNames: ["AgentProfile", "AgentProfileCatalog"],
            persistenceMayBeSQLite: true,
            uiMustNotImportMCPServer: true
        ),
        AppLayerFeatureContract(
            feature: .pluginCredentials,
            structureTypeNames: ["PluginSecretDescriptor", "PluginCredentialGroup"],
            persistenceMayBeSQLite: true,
            uiMustNotImportMCPServer: true
        ),
        AppLayerFeatureContract(
            feature: .pluginFactoryManifests,
            structureTypeNames: ["PluginFactoryManifestRecord", "PluginFactoryManifestCatalog"],
            persistenceMayBeSQLite: true,
            uiMustNotImportMCPServer: true
        ),
        AppLayerFeatureContract(
            feature: .hostHTTPSecrets,
            structureTypeNames: ["HostHTTPAccessGate", "HostHTTPSecretAttacher"],
            persistenceMayBeSQLite: false,
            uiMustNotImportMCPServer: true
        ),
        AppLayerFeatureContract(
            feature: .scriptReview,
            structureTypeNames: ["ScriptReviewer", "ScriptExecutionArguments"],
            persistenceMayBeSQLite: false,
            uiMustNotImportMCPServer: false
        ),
        AppLayerFeatureContract(
            feature: .mcpToolCatalog,
            structureTypeNames: ["AllowedMCPTool"],
            persistenceMayBeSQLite: false,
            uiMustNotImportMCPServer: true
        ),
        AppLayerFeatureContract(
            feature: .conversationMCPBridge,
            structureTypeNames: ["AllowedMCPTool"],
            persistenceMayBeSQLite: false,
            uiMustNotImportMCPServer: false
        ),
    ]

    public static func contract(for feature: AppLayerFeature) -> AppLayerFeatureContract {
        contracts.first { $0.feature == feature }!
    }
}
