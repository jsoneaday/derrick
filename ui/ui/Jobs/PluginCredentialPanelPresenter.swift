import AppKit
import Foundation
import Structure
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
        let fields = payload?.fields ?? []
        let pluginID = payload?.pluginID ?? ""
        let mode = payload?.mode ?? .requireMissing

        let root = ConnectorCredentialForm(
            pluginID: pluginID,
            fields: fields,
            mode: mode,
            onSave: { [weak self] values in
                self?.saveAndFinish(
                    request: request,
                    pluginID: pluginID,
                    fields: fields,
                    values: values
                )
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
        fields: [PluginCredentialFieldPresentation],
        values: [String: String]
    ) {
        do {
            try ConnectorCredentialSaver.savePartial(pluginID: pluginID, fields: fields, drafts: values)
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
