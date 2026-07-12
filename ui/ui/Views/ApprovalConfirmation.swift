import SwiftUI

struct ApprovalConfirmation: View {
    let request: ApprovalConfirmationRequest
    @ObservedObject var model: ApprovalPresentationModel
    let onCancel: () -> Void
    let onApprove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tool Invocation Approval")
                    .font(.headline)
                Text("The agent is requesting to call the tool: \(request.toolName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Arguments (JSON)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $model.editedArgumentsJSON)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 150)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Actor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Actor name", text: $model.actor)
                    .textFieldStyle(.roundedBorder)
            }

            if let error = model.validationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button("Approve") {
                    onApprove()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}
