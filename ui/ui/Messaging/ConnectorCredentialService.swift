import DBRepository
import Foundation
import Plugin
import ServiceContracts
import SwiftUI

/// Shared credential form: all fields shown, stored values obfuscated, partial Keychain updates.
struct ConnectorCredentialForm: View {
    let pluginID: String
    let fields: [PluginCredentialFieldPresentation]
    let mode: PluginCredentialCollectionMode
    let onSave: ([String: String]) -> Void
    let onCancel: () -> Void

    @State private var drafts: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .font(ModalChrome.symbolFont)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color(red: 0.176, green: 0.286, blue: 0.576))
                Text("Plugin credentials")
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 10) {
                Text("Stored in Keychain for \(pluginID). Values never enter the plugin sandbox.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(fields) { field in
                    fieldRow(field)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .buttonStyle(ModalSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Save in Keychain") {
                    onSave(drafts)
                }
                .buttonStyle(ModalPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .padding(.top, 4)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: ModalPopupDefaults.cornerRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .clipShape(RoundedRectangle(cornerRadius: ModalPopupDefaults.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ModalPopupDefaults.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(16)
        .preferredColorScheme(.light)
        .onAppear {
            var initial: [String: String] = [:]
            for field in fields {
                initial[field.id] = ""
            }
            drafts = initial
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: PluginCredentialFieldPresentation) -> some View {
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
                    text: binding(for: field.id)
                )
                .textFieldStyle(.roundedBorder)
            } else {
                TextField(
                    field.hasStoredValue ? "Leave blank to keep saved value" : field.label,
                    text: binding(for: field.id)
                )
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var canSave: Bool {
        ConnectorCredentialSaver.canSave(fields: fields, drafts: drafts, mode: mode)
    }

    private func binding(for id: String) -> Binding<String> {
        Binding(
            get: { drafts[id] ?? "" },
            set: { drafts[id] = $0 }
        )
    }
}

/// Presents connector credential collection from Messaging, Settings, and chat flows.
@MainActor
enum ConnectorCredentialService {
    enum Result: Equatable {
        case ok
        case cancelled
    }

    static func present(
        pluginID: String,
        secrets: [PluginSecretDescriptor],
        mode: PluginCredentialCollectionMode
    ) async -> Result {
        guard !secrets.isEmpty else { return .ok }
        let payload = PluginCredentialPromptPayload(pluginID: pluginID, secrets: secrets, mode: mode)
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
                requiredFields: secrets.map(\.id)
            )
        )
        guard decision.approved else { return .cancelled }
        let fields = payload.fields
        let stillMissing = PluginSecretKeychain.missingIDs(pluginID: pluginID, fields: secrets)
        if mode == .requireMissing, !stillMissing.isEmpty {
            return .cancelled
        }
        return .ok
    }

    static func secretDescriptors(
        pluginID: String,
        repository: DBRepository
    ) async -> [PluginSecretDescriptor] {
        await PluginCredentialCatalog.secretDescriptors(pluginID: pluginID, repository: repository)
    }

    static func connectorPluginIDs(repository: DBRepository) async -> [String] {
        await PluginCredentialCatalog.connectorPluginIDs(repository: repository)
    }
}
