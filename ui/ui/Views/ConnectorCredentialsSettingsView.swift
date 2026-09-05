import DBRepository
import Foundation
import Structure
import SwiftUI

private struct ConnectorCredentialRow: Identifiable {
    let pluginID: String
    let secrets: [PluginSecretDescriptor]
    let missingCount: Int

    var id: String { pluginID }
}

struct ConnectorCredentialsSettingsView: View {
    let repository: DBRepository
    @State private var rows: [ConnectorCredentialRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Connectors")
                .font(.system(size: 26, weight: .semibold, design: .rounded))

            Text("Messaging connector credentials are stored in Keychain. Update a token or password here when a connector plugin is installed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if rows.isEmpty {
                Text("No connector plugins are installed yet.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        connectorRow(row)
                        if row.id != rows.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task { await reload() }
    }

    @ViewBuilder
    private func connectorRow(_ row: ConnectorCredentialRow) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.pluginID)
                    .font(.body.weight(.medium))
                Text(credentialSummary(row: row))
                    .font(.caption)
                    .foregroundStyle(row.missingCount == 0 ? Color.secondary : Color.orange)
            }
            Spacer(minLength: 8)
            Button("Credentials…") {
                Task {
                    guard !row.secrets.isEmpty else { return }
                    _ = await ConnectorCredentialService.present(
                        pluginID: row.pluginID,
                        secrets: row.secrets,
                        mode: .allowPartialUpdate
                    )
                    await reload()
                }
            }
            .buttonStyle(.bordered)
            .disabled(row.secrets.isEmpty)
        }
        .padding(.vertical, 10)
    }

    private func credentialSummary(row: ConnectorCredentialRow) -> String {
        guard !row.secrets.isEmpty else { return "No credentials declared" }
        if row.missingCount == 0 {
            return "All \(row.secrets.count) credential\(row.secrets.count == 1 ? "" : "s") saved"
        }
        if row.missingCount == row.secrets.count {
            return "Credentials not set"
        }
        return "\(row.missingCount) of \(row.secrets.count) credential\(row.secrets.count == 1 ? "" : "s") missing"
    }

    private func reload() async {
        let connectorIDs = await ConnectorCredentialService.connectorPluginIDs(repository: repository)
        var loaded: [ConnectorCredentialRow] = []
        for pluginID in connectorIDs {
            let secrets = await ConnectorCredentialService.secretDescriptors(
                pluginID: pluginID,
                repository: repository
            )
            let missing = PluginSecretKeychain.missingIDs(pluginID: pluginID, fields: secrets)
            loaded.append(
                ConnectorCredentialRow(
                    pluginID: pluginID,
                    secrets: secrets,
                    missingCount: missing.count
                )
            )
        }
        rows = loaded
    }
}
