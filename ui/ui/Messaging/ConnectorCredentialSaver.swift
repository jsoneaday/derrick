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
            let missing = fields.filter { !$0.hasStoredValue }
            let missingFilled = missing.allSatisfy { field in
                let draft = drafts[field.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return !draft.isEmpty
            }
            if !missingFilled { return false }
            return true
        }
    }
}
