import AppKit
import DBRepository
import EgressProxy
import Foundation
import PolicyUserInteraction
import Structure
import SwiftUI

/// Themed HITL approval card for notification taps (matches ModalPopup / job-result chrome).
@MainActor
final class HITLApprovalPanelPresenter {
    static let shared = HITLApprovalPanelPresenter()

    private var panel: NSPanel?
    private var continuation: CheckedContinuation<(approved: Bool, always: Bool)?, Never>?

    private init() {}

    func present(row: PendingHITLApprovalRow) async -> (approved: Bool, always: Bool)? {
        if continuation != nil {
            return nil
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            showPanel(for: row)
        }
    }

    private func showPanel(for row: PendingHITLApprovalRow) {
        dismissPanel(keepingContinuation: true)

        let isNetwork = HITLOfflineNetworkService.isNetworkToolName(row.toolName)
        let host = HITLOfflineNetworkService.host(fromNetworkToolName: row.toolName)
        let suffix = host.map { EgressHostExtractor.permanentSuffix(for: $0) }
        let fields = HITLNetworkArguments.parse(row.argumentsJSON)

        let root = HITLApprovalStandaloneCard(
            isNetwork: isNetwork,
            host: host,
            suffix: suffix,
            blacklistPattern: fields.blacklistPattern,
            requestURL: fields.url,
            toolName: row.toolName,
            argumentsJSON: row.argumentsJSON,
            onAlways: { [weak self] in self?.finish((true, true)) },
            onOnce: { [weak self] in self?.finish((true, false)) },
            onAllow: { [weak self] in self?.finish((true, false)) },
            onDeny: { [weak self] in self?.finish((false, false)) }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 512, height: 280)

        let panel = HITLApprovalKeyablePanel(
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
            let origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2
            )
            panel.setFrameOrigin(origin)
        }

        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func finish(_ outcome: (approved: Bool, always: Bool)?) {
        continuation?.resume(returning: outcome)
        continuation = nil
        dismissPanel(keepingContinuation: false)
    }

    private func dismissPanel(keepingContinuation: Bool) {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        if !keepingContinuation, continuation != nil {
            continuation?.resume(returning: nil)
            continuation = nil
        }
    }
}

// Reuse the keyable panel type from JobResultPresenter.swift (same file target).
// JobResultKeyablePanel is fileprivate there — duplicate a tiny alias here.
private final class HITLApprovalKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct HITLApprovalStandaloneCard: View {
    let isNetwork: Bool
    let host: String?
    let suffix: String?
    let blacklistPattern: String?
    let requestURL: String?
    let toolName: String
    let argumentsJSON: String
    let onAlways: () -> Void
    let onOnce: () -> Void
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            bodyContent
            footer
        }
        .frame(width: 480)
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
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: isNetwork ? "network" : "checkmark.shield")
                .font(ModalChrome.symbolFont)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(ModalChrome.symbolColor(for: isNetwork ? .networkAccessRequest : .approvalRequired))
            Text(isNetwork ? (blacklistPattern == nil ? "Network access" : "Network blacklist") : "Approval needed")
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(.caption, design: .default))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !isNetwork {
                let preview = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
                if !preview.isEmpty {
                    Text(preview.count > 280 ? String(preview.prefix(280)) + "…" : preview)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Button("Deny", action: onDeny)
                .buttonStyle(ModalSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            if isNetwork {
                Button(blacklistPattern == nil ? "Allow once" : "This run", action: onOnce)
                    .buttonStyle(ModalSecondaryButtonStyle())
                    .lineLimit(1)
                Button("Always", action: onAlways)
                    .buttonStyle(ModalPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Allow", action: onAllow)
                    .buttonStyle(ModalPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .padding(.top, 4)
    }

    private var summary: String {
        if isNetwork, let blacklistPattern {
            let url = requestURL ?? host.map { "https://\($0)" } ?? "this host"
            return "This script wants \(url) which matches blacklist \(blacklistPattern)."
        }
        if isNetwork, let suffix {
            return "Allow *.\(suffix)?"
        }
        return "Allow the agent to run “\(toolName)”?"
    }

    private var detail: String? {
        if isNetwork, let blacklistPattern {
            return "This run allows this invoke only. Always removes \(blacklistPattern) from Settings → Network blacklist. Deny stops this request."
        }
        if isNetwork, let suffix, let host {
            return "Includes \(host) and every subdomain of \(suffix). Always saves “\(suffix)” for future runs."
        }
        return nil
    }
}

private enum HITLNetworkArguments {
    static func parse(_ json: String) -> (url: String?, blacklistPattern: String?) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let url = object["url"] as? String
        let kind = object["kind"] as? String
        let pattern = object["pattern"] as? String
        if kind == "blacklist" {
            return (url, pattern)
        }
        return (url, nil)
    }
}
