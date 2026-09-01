import DBRepository
import Foundation
import Plugin
import ServiceContracts

/// Credential prompt when a messaging connector is opened.
@MainActor
enum MessagingConnectorCredentials {
    enum EnsureResult: Equatable {
        case ok
        case cancelled
        case dotenvMissing(message: String)
    }

    static func ensureIfNeeded(pluginID: String, repository: DBRepository) async -> EnsureResult {
        let manifests = (try? await repository.listLatestPluginFactoryManifests()) ?? []
        guard let row = manifests.first(where: { $0.pluginID == pluginID }) else { return .ok }
        let fields = PluginSecretField.fields(fromManifestJSON: Data(row.manifestJSON.utf8))
        guard !fields.isEmpty else { return .ok }

        let descriptors = fields.map(\.descriptor)
        let missing = PluginSecretKeychain.missingIDs(pluginID: pluginID, fields: descriptors)
        guard !missing.isEmpty else { return .ok }

        if PluginSecretResolver.usesDotenvOnly {
            let fieldID = missing.first?.id ?? "secret"
            return .dotenvMissing(
                message: PluginSecretResolver.missingDotenvMessage(
                    pluginID: pluginID,
                    fieldID: fieldID
                )
            )
        }

        let payload = PluginCredentialPromptPayload(pluginID: pluginID, secrets: missing)
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8)
        else {
            return .cancelled
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
        guard decision.approved else { return .cancelled }
        return PluginSecretKeychain.missingIDs(pluginID: pluginID, fields: missing).isEmpty ? .ok : .cancelled
    }
}
