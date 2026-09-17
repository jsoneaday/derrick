import SwiftUI

enum PluginsWorkspaceSubtab: String, CaseIterable, Identifiable, Hashable {
    case create = "Create plugin"
    case plugins = "Plugins"

    var id: String { rawValue }
}

/// Plugins tab chrome: Create plugin Q&A and Plugins package browser as pill sub-tabs.
struct PluginsWorkspaceShellView<CreateContent: View>: View {
    @ViewBuilder var createContent: () -> CreateContent
    @State private var subtab: PluginsWorkspaceSubtab = .create
    @StateObject private var browser = PluginPackageBrowserController()

    var body: some View {
        VStack(spacing: 0) {
            PillSubtabBar(
                tabs: Array(PluginsWorkspaceSubtab.allCases),
                selection: $subtab,
                title: { $0.rawValue },
                accessibilityIdentifier: "plugins-workspace-subtabs"
            )

            Group {
                switch subtab {
                case .create:
                    createContent()
                case .plugins:
                    PluginPackageBrowserView(controller: browser)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: subtab) { _, newValue in
            if newValue == .plugins {
                Task { await browser.reloadList() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ChatShellNotification.pluginFactorySucceeded)) { notification in
            guard let pluginID = notification.userInfo?[ChatShellNotification.pluginIDUserInfoKey] as? String,
                  !pluginID.isEmpty
            else { return }
            let version = notification.userInfo?[ChatShellNotification.pluginVersionUserInfoKey] as? String
            subtab = .plugins
            Task { await browser.handleFactorySucceeded(pluginID: pluginID, version: version) }
        }
    }
}
