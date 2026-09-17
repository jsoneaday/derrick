import Structure
import SwiftUI

struct PluginPackageBrowserView: View {
    @ObservedObject var controller: PluginPackageBrowserController

    private let chromeFill = Color(red: 248.0 / 255.0, green: 248.0 / 255.0, blue: 246.0 / 255.0)
    private let sidebarWidth: CGFloat = 220
    private let filesWidth: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                pluginSidebar
                    .frame(width: sidebarWidth)
                    .background(chromeFill)

                Divider()

                fileSidebar
                    .frame(width: filesWidth)
                    .background(chromeFill.opacity(0.7))

                Divider()

                readerPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            editComposer
        }
        .background(chromeFill)
        .task {
            await controller.reloadList()
        }
    }

    private var pluginSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Plugins")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if controller.groups.isEmpty {
                Text("No plugins yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                Spacer()
            } else {
                List {
                    ForEach(controller.groups) { group in
                        DisclosureGroup(
                            isExpanded: expansionBinding(for: group.pluginID)
                        ) {
                            ForEach(group.releases) { release in
                                Button {
                                    Task {
                                        await controller.selectVersion(
                                            release.version,
                                            pluginID: group.pluginID
                                        )
                                    }
                                } label: {
                                    HStack {
                                        Text("v\(release.version)")
                                            .font(.caption.monospaced())
                                        Spacer(minLength: 0)
                                        if group.pluginID == controller.selectedPluginID,
                                           release.version == controller.selectedVersion {
                                            Image(systemName: "checkmark")
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        } label: {
                            Button {
                                Task { await controller.selectPlugin(group.pluginID) }
                            } label: {
                                Text("/\(group.pluginID)")
                                    .font(.system(.body, design: .monospaced))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .accessibilityIdentifier("plugin-package-browser-sidebar")
    }

    private var fileSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Files")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if controller.selectedVersion == nil {
                Text("Select a plugin")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                Spacer()
            } else if controller.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(12)
                Spacer()
            } else if controller.filePaths.isEmpty {
                Text("No package files")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                Spacer()
            } else {
                List(selection: Binding(
                    get: { controller.selectedFilePath },
                    set: { path in
                        if let path { controller.selectFile(path) }
                    }
                )) {
                    ForEach(controller.filePaths, id: \.self) { path in
                        Text(path)
                            .font(.caption.monospaced())
                            .lineLimit(2)
                            .tag(path)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .accessibilityIdentifier("plugin-package-browser-files")
    }

    private var readerPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.selectedFilePath ?? "Package file")
                        .font(.subheadline.weight(.semibold).monospaced())
                        .lineLimit(1)
                    if let pluginID = controller.selectedPluginID,
                       let version = controller.selectedVersion {
                        Text("/\(pluginID) · v\(version) · read only")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
            }

            if controller.selectedFilePath == nil {
                ContentUnavailableView(
                    "Choose a file",
                    systemImage: "doc.text",
                    description: Text("Pick a plugin version to inspect plugin.json, SKILL.md, references, or Go source.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(controller.selectedFileText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .accessibilityIdentifier("plugin-package-file-reader")
            }

            if let error = controller.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            } else if let status = controller.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
        }
    }

    private var editComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Update plugin")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    controller.selectedPluginID == nil
                        ? "Select a plugin to describe a change"
                        : "Describe the change for /\(controller.selectedPluginID ?? "")…",
                    text: $controller.editPrompt,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .disabled(controller.selectedPluginID == nil)
                .accessibilityIdentifier("plugin-package-edit-prompt")

                Button("Update") {
                    controller.submitEditPrompt()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.canSubmitEdit)
                .keyboardShortcut(.defaultAction)
            }
            Text("Derrick rebuilds a new version via the factory. Package files stay read-only here.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(chromeFill)
    }

    private func expansionBinding(for pluginID: String) -> Binding<Bool> {
        Binding(
            get: { controller.expandedPluginIDs.contains(pluginID) },
            set: { expanded in
                if expanded {
                    controller.expandedPluginIDs.insert(pluginID)
                    Task { await controller.selectPlugin(pluginID) }
                } else {
                    controller.expandedPluginIDs.remove(pluginID)
                }
            }
        )
    }
}
