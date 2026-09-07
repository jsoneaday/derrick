import Foundation
import Structure

/// Saves plugin connector credentials to Keychain. Only non-empty drafts are written.
enum ConnectorCredentialSaver {
    static func savePartial(
        pluginID: String,
        fields: [PluginCredentialFieldPresentation],
        drafts: [String: String]
    ) throws {
        for field in fields {
            let draft = drafts[field.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !draft.isEmpty else { continue }
            try PluginSecretKeychain.save(pluginID: pluginID, fieldID: field.id, value: draft)
        }
    }

    /// Writes drafts and copies `.env` values into the shared Keychain the daemon reads.
    static func persistRequired(
        pluginID: String,
        fields: [PluginCredentialFieldPresentation],
        drafts: [String: String]
    ) throws {
        try savePartial(pluginID: pluginID, fields: fields, drafts: drafts)
        PluginSecretKeychain.promoteToSharedGroup(pluginID: pluginID, fields: fields.map(\.descriptor))
        try PluginSecretHostMirror.syncDevelopmentSecretsToKeychainOrThrow(
            pluginID: pluginID,
            fields: fields.map(\.descriptor)
        )
        let missing = PluginSecretKeychain.missingKeychainIDs(
            pluginID: pluginID,
            fields: fields.map(\.descriptor)
        )
        guard missing.isEmpty else {
            throw PluginSecretKeychainError.notStoredForDaemon
        }
    }

    static func canSave(
        fields: [PluginCredentialFieldPresentation],
        drafts: [String: String],
        mode: PluginCredentialCollectionMode
    ) -> Bool {
        switch mode {
        case .requireMissing:
            return fields.allSatisfy { field in
                if field.hasStoredValue { return true }
                let draft = drafts[field.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return !draft.isEmpty
            }
        case .allowPartialUpdate:
            let missingFilled = fields.filter { !$0.hasStoredValue }.allSatisfy { field in
                let draft = drafts[field.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return !draft.isEmpty
            }
            guard missingFilled else { return false }
            return fields.contains { field in
                let draft = drafts[field.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return !draft.isEmpty
            }
        }
    }
}
