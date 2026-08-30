import SwiftUI

struct LLMProviderSetupModalBody: View {
    let onEnterAPIKey: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Derrick needs at least one LLM provider API key before you can chat.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                Text("Supported providers")
                    .font(.subheadline.weight(.semibold))
                VStack(alignment: .leading, spacing: 6) {
                    providerRow(
                        name: "OpenAI",
                        detail: LLMProviderCredentialGate.configurationHint(for: .openai)
                    )
                    providerRow(
                        name: "Google Gemini",
                        detail: LLMProviderCredentialGate.configurationHint(for: .google)
                    )
                }
            }

            Group {
                Text("Not supported")
                    .font(.subheadline.weight(.semibold))
                Text("Anthropic (Claude) does not allow third-party agent harnesses, so Derrick cannot use Claude today.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !LLMProviderCredentialGate.usesDotenvSecrets() {
                Button("Enter API Key…") {
                    onEnterAPIKey()
                }
                .buttonStyle(ModalSecondaryButtonStyle())
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func providerRow(name: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.subheadline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
