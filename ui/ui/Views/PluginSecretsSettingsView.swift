import SwiftUI

struct PluginSecretsSettingsView: View {
    @State private var telegramToken = ""
    @State private var googleToken = ""
    @State private var telegramSaved = false
    @State private var googleSaved = false
    @State private var telegramPresent = false
    @State private var googlePresent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            secretRow(
                title: "Telegram bot token",
                help: "Attached only to api.telegram.org. Path is rewritten on the host.",
                text: $telegramToken,
                present: telegramPresent,
                saved: telegramSaved
            ) {
                await SoftwareFactorySettingsService.shared.savePluginSecret(
                    provider: "telegram",
                    material: telegramToken
                )
                telegramSaved = true
                telegramPresent = !(telegramToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            secretRow(
                title: "Google access token",
                help: "Attached as Bearer only to Gmail/Google APIs. Token endpoints are never attached.",
                text: $googleToken,
                present: googlePresent,
                saved: googleSaved
            ) {
                await SoftwareFactorySettingsService.shared.savePluginSecret(
                    provider: "google",
                    material: googleToken
                )
                googleSaved = true
                googlePresent = !(googleToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .task {
            telegramPresent = await SoftwareFactorySettingsService.shared.hasPluginSecret(provider: "telegram")
            googlePresent = await SoftwareFactorySettingsService.shared.hasPluginSecret(provider: "google")
        }
    }

    private func secretRow(
        title: String,
        help: String,
        text: Binding<String>,
        present: Bool,
        saved: Bool,
        onSave: @escaping () async -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                if present {
                    Text("saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if saved {
                    Text("updated")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("Paste token", text: text)
                .textFieldStyle(.roundedBorder)
            Button("Save") {
                Task { await onSave() }
            }
        }
    }
}
