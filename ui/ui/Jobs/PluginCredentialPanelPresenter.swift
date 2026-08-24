import AppKit
import Foundation
import ServiceContracts
import SwiftUI

/// Collects plugin Keychain credentials using the labels from plugin.json.
@MainActor
final class PluginCredentialPanelPresenter {
    static let shared = PluginCredentialPanelPresenter()

    private var panel: NSPanel?
    private var continuation: CheckedContinuation<AgentApprovalDecisionDTO, Never>?

    private init() {}

    func present(_ request: AgentApprovalRequestDTO) async -> AgentApprovalDecisionDTO {
        if continuation != nil {
            return AgentApprovalDecisionDTO(
                approvalID: request.approvalID,
                approved: false,
                editedArgumentsJSON: request.argumentsJSON,
                actor: "system-busy"
            )
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            showPanel(for: request)
        }
    }

    private func showPanel(for request: AgentApprovalRequestDTO) {
        dismissPanel(keepingContinuation: true)
        let payload = decodePayload(request.argumentsJSON)
        let fields = payload?.secrets ?? []
        let pluginID = payload?.pluginID ?? ""

        let root = PluginCredentialCard(
            pluginID: pluginID,
            fields: fields,
            onSave: { [weak self] values in
                self?.saveAndFinish(request: request, pluginID: pluginID, values: values)
            },
            onCancel: { [weak self] in
                self?.finish(
                    AgentApprovalDecisionDTO(
                        approvalID: request.approvalID,
                        approved: false,
                        editedArgumentsJSON: request.argumentsJSON,
                        actor: "ui-credential-cancel"
                    )
                )
            }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 360)

        let panel = PluginCredentialKeyablePanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(
                NSPoint(
                    x: visible.midX - size.width / 2,
                    y: visible.midY - size.height / 2
                )
            )
        }

        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func saveAndFinish(
        request: AgentApprovalRequestDTO,
        pluginID: String,
        values: [String: String]
    ) {
        do {
            for (fieldID, value) in values {
                try PluginSecretKeychain.save(pluginID: pluginID, fieldID: fieldID, value: value)
            }
            finish(
                AgentApprovalDecisionDTO(
                    approvalID: request.approvalID,
                    approved: true,
                    editedArgumentsJSON: #"{"stored":true}"#,
                    actor: "ui-credential-save"
                )
            )
        } catch {
            finish(
                AgentApprovalDecisionDTO(
                    approvalID: request.approvalID,
                    approved: false,
                    editedArgumentsJSON: request.argumentsJSON,
                    actor: "ui-credential-save-failed"
                )
            )
        }
    }

    private func finish(_ decision: AgentApprovalDecisionDTO) {
        continuation?.resume(returning: decision)
        continuation = nil
        dismissPanel(keepingContinuation: false)
    }

    private func dismissPanel(keepingContinuation: Bool) {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        if !keepingContinuation, continuation != nil {
            continuation?.resume(
                returning: AgentApprovalDecisionDTO(
                    approvalID: "",
                    approved: false,
                    editedArgumentsJSON: "",
                    actor: "ui-credential-dismissed"
                )
            )
            continuation = nil
        }
    }

    private func decodePayload(_ json: String) -> PluginCredentialPromptPayload? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PluginCredentialPromptPayload.self, from: data)
    }
}

private final class PluginCredentialKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct PluginCredentialCard: View {
    let pluginID: String
    let fields: [PluginSecretDescriptor]
    let onSave: ([String: String]) -> Void
    let onCancel: () -> Void

    @State private var values: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .font(ModalChrome.symbolFont)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color(red: 0.176, green: 0.286, blue: 0.576))
                Text("Save plugin credentials")
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 10) {
                Text("Derrick will store these in Keychain for \(pluginID). They are not sent into the plugin sandbox.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(fields, id: \.id) { field in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(field.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if field.usesSecureField {
                            SecureField(field.label, text: binding(for: field.id))
                                .textFieldStyle(.roundedBorder)
                        } else {
                            TextField(field.label, text: binding(for: field.id))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
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
                    onSave(values)
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
            values = initial
        }
    }

    private var canSave: Bool {
        fields.allSatisfy { field in
            !(values[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func binding(for id: String) -> Binding<String> {
        Binding(
            get: { values[id] ?? "" },
            set: { values[id] = $0 }
        )
    }
}
