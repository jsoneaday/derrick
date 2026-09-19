import Plugin
import Structure
import SwiftUI

/// Installed factory plugins, shown in Account settings (not the app sidebar).
struct PluginFactorySettingsListView: View {
    @ObservedObject private var pluginFactoryList = PluginFactoryListStore.shared
    @State private var expandedPluginIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            VStack(alignment: .leading, spacing: SettingsLayout.headerControlSpacing) {
                Text("Installed plugins")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 10) {
                    Button("Create plugin") {
                        NotificationCenter.default.post(
                            name: ChatShellNotification.startPluginCreation,
                            object: nil
                        )
                    }
                    .buttonStyle(.borderedProminent)

                    if pluginFactoryList.releases.isEmpty {
                        Text("No plugins yet")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(pluginFactoryList.groups) { group in
                            pluginGroupRow(group)
                        }
                    }
                    if let error = pluginFactoryList.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, SettingsLayout.fieldIndent)
                Text("Type / and the plugin name in Chat to open it in a tab. Plugins opens Create plugin and a browser for installed package files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, SettingsLayout.fieldIndent)
            }
        }
        .task {
            await pluginFactoryList.reload()
        }
    }

    private func pluginGroupRow(_ group: PluginFactoryReleaseGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    if expandedPluginIDs.contains(group.pluginID) {
                        expandedPluginIDs.remove(group.pluginID)
                    } else {
                        expandedPluginIDs.insert(group.pluginID)
                    }
                } label: {
                    Image(systemName: expandedPluginIDs.contains(group.pluginID)
                        ? "chevron.down"
                        : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button {
                    NotificationCenter.default.post(
                        name: ChatShellNotification.openPluginInChat,
                        object: nil,
                        userInfo: [ChatShellNotification.pluginIDUserInfoKey: group.pluginID]
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("/\(group.pluginID)")
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                        Text(group.releases.count == 1
                            ? "v\(group.latest?.version ?? "")"
                            : "\(group.releases.count) versions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            if expandedPluginIDs.contains(group.pluginID) {
                ForEach(group.releases) { release in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("v\(release.version)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(release.reviewSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            Task { await pluginFactoryList.delete(release) }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Delete \(release.pluginID) \(release.version)")
                    }
                    .padding(.leading, 22)
                }
            }
        }
    }
}
