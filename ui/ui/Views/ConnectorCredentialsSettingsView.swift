import DBRepository
import Foundation
import Structure
import SwiftUI

struct CredentialsSettingsView: View {
    let repository: DBRepository
    @State private var pluginGroups: [PluginCredentialGroup] = []
    @State private var providerDrafts: [String: String] = [:]
    @State private var pluginDrafts: [String: String] = [:]
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var refreshToken = 0

    private var usesDotenvForChatKeys: Bool {
        LLMProviderCredentialGate.usesDotenvSecrets()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Credentials")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("API keys and plugin tokens are stored in Keychain on this Mac. Leave a field blank to keep the saved value.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? Color.red : Color.secondary)
            }

            chatProvidersSection
            pluginsSection
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task { await reloadPlugins() }
    }

    private var chatProvidersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Chat")
                .font(.headline)
            if usesDotenvForChatKeys {
                Text("This build reads chat API keys from a local file instead of Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(LLMProviderChoice.allCases, id: \.id) { provider in
                providerRow(provider)
            }
        }
    }

    private var pluginsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Plugins")
                .font(.headline)
            if pluginGroups.isEmpty {
                Text("No installed plugins need credentials yet.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(pluginGroups) { group in
                    pluginGroup(group)
                }
            }
        }
    }

    @ViewBuilder
    private func providerRow(_ provider: LLMProviderChoice) -> some View {
        let stored = providerHasKeychainValue(provider)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(provider.apiKeyName)
                    .font(.body.weight(.medium))
                Spacer()
                Text(stored ? "Saved" : "Not set")
                    .font(.caption)
                    .foregroundStyle(stored ? Color.secondary : Color.orange)
            }
            if usesDotenvForChatKeys {
                Text(LLMProviderCredentialGate.configurationHint(for: provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                SecureField(
                    stored ? "Leave blank to keep saved value" : provider.apiKeyName,
                    text: providerDraftBinding(provider)
                )
                .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Save") {
                        saveProviderKey(provider)
                    }
                    .disabled(!canSaveProvider(provider))
                }
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func pluginGroup(_ group: PluginCredentialGroup) -> some View {
        let fields = PluginCredentialFieldPresentation.presentations(
            for: group.secrets,
            pluginID: group.pluginID
        )
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.displayName)
                        .font(.body.weight(.medium))
                    Text(group.isConnector ? "Messaging connector" : "Plugin")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(pluginStatus(fields: fields))
                    .font(.caption)
                    .foregroundStyle(fields.contains(where: { !$0.hasStoredValue }) ? Color.orange : Color.secondary)
            }
            if group.pluginID.localizedCaseInsensitiveContains("slack") {
                Text(ConnectorReplyThreadAccessMessage.slackSetupHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(fields) { field in
                pluginFieldRow(group: group, field: field)
            }
            HStack {
                Spacer()
                Button("Save") {
                    savePlugin(group: group, fields: fields)
                }
                .disabled(
                    !ConnectorCredentialSaver.canSave(
                        fields: fields,
                        drafts: drafts(for: group),
                        mode: .allowPartialUpdate
                    )
                )
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func pluginFieldRow(group: PluginCredentialGroup, field: PluginCredentialFieldPresentation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if field.hasStoredValue {
                Text(String(repeating: "•", count: 12))
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Saved value hidden")
            }
            if field.usesSecureField {
                SecureField(
                    field.hasStoredValue ? "Leave blank to keep saved value" : field.label,
                    text: pluginDraftBinding(pluginID: group.pluginID, fieldID: field.id)
                )
                .textFieldStyle(.roundedBorder)
            } else {
                TextField(
                    field.hasStoredValue ? "Leave blank to keep saved value" : field.label,
                    text: pluginDraftBinding(pluginID: group.pluginID, fieldID: field.id)
                )
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func providerHasKeychainValue(_ provider: LLMProviderChoice) -> Bool {
        _ = refreshToken
        return AppSecretResolver().resolve(
            account: provider.secretAccount,
            environmentKeys: provider.apiKeyEnvironmentKeys,
            policy: .keychainOnly
        ) != nil
    }

    private func canSaveProvider(_ provider: LLMProviderChoice) -> Bool {
        let draft = providerDrafts[provider.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !draft.isEmpty
    }

    private func saveProviderKey(_ provider: LLMProviderChoice) {
        let value = providerDrafts[provider.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return }
        do {
            try SecretStore(
                service: DerrickAppSupport.hostAppBundleIdentifier,
                account: provider.secretAccount
            ).save(value)
            providerDrafts[provider.id] = ""
            setStatus("Saved \(provider.apiKeyName).")
            refreshToken += 1
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
    }

    private func savePlugin(group: PluginCredentialGroup, fields: [PluginCredentialFieldPresentation]) {
        do {
            try ConnectorCredentialSaver.persistRequired(
                pluginID: group.pluginID,
                fields: fields,
                drafts: drafts(for: group)
            )
            for field in fields {
                pluginDrafts[draftKey(pluginID: group.pluginID, fieldID: field.id)] = ""
            }
            setStatus("Saved credentials for \(group.displayName).")
            refreshToken += 1
            Task { await reloadPlugins() }
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
    }

    private func pluginStatus(fields: [PluginCredentialFieldPresentation]) -> String {
        let missing = fields.filter { !$0.hasStoredValue }.count
        if fields.isEmpty { return "No credentials declared" }
        if missing == 0 { return "Saved" }
        if missing == fields.count { return "Not set" }
        return "\(missing) of \(fields.count) missing"
    }

    private func drafts(for group: PluginCredentialGroup) -> [String: String] {
        Dictionary(uniqueKeysWithValues: group.secrets.map { secret in
            (secret.id, pluginDrafts[draftKey(pluginID: group.pluginID, fieldID: secret.id)] ?? "")
        })
    }

    private func providerDraftBinding(_ provider: LLMProviderChoice) -> Binding<String> {
        Binding(
            get: { providerDrafts[provider.id] ?? "" },
            set: { providerDrafts[provider.id] = $0 }
        )
    }

    private func pluginDraftBinding(pluginID: String, fieldID: String) -> Binding<String> {
        let key = draftKey(pluginID: pluginID, fieldID: fieldID)
        return Binding(
            get: { pluginDrafts[key] ?? "" },
            set: { pluginDrafts[key] = $0 }
        )
    }

    private func draftKey(pluginID: String, fieldID: String) -> String {
        "\(pluginID)\u{1e}\(fieldID)"
    }

    private func setStatus(_ message: String, isError: Bool = false) {
        statusMessage = message
        statusIsError = isError
    }

    private func reloadPlugins() async {
        pluginGroups = await PluginCredentialCatalog.pluginsWithSecrets(repository: repository)
    }
}
