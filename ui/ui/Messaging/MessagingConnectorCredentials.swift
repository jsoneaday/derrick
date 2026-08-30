import DBRepository
import Foundation
import Plugin
import ServiceContracts

/// Keychain credential prompt when a messaging connector is opened.
@MainActor
enum MessagingConnectorCredentials {
    static func ensureIfNeeded(pluginID: String, repository: DBRepository) async -> Bool {
        let manifests = (try? await repository.listLatestPluginFactoryManifests()) ?? []
        guard let row = manifests.first(where: { $0.pluginID == pluginID }) else { return true }
        let fields = PluginSecretField.fields(fromManifestJSON: Data(row.manifestJSON.utf8))
        guard !fields.isEmpty else { return true }

        let descriptors = fields.map(\.descriptor)
        let missing = PluginSecretKeychain.missingIDs(pluginID: pluginID, fields: descriptors)
        guard !missing.isEmpty else { return true }
        if PluginSecretResolver.usesDotenvOnly { return true }

        let payload = PluginCredentialPromptPayload(pluginID: pluginID, secrets: missing)
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8)
        else {
            return false
        }

        let decision = await PluginCredentialPanelPresenter.shared.present(
            AgentApprovalRequestDTO(
                approvalID: UUID().uuidString,
                turnID: "",
                sessionID: "",
                toolName: PluginCredentialPrompt.toolName,
                argumentsJSON: json,
                requiredFields: missing.map(\.id)
            )
        )
        guard decision.approved else { return false }
        return PluginSecretKeychain.missingIDs(pluginID: pluginID, fields: missing).isEmpty
    }
}
