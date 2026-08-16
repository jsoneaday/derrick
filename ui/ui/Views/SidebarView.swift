import SwiftUI
import DBRepository
import ServiceContracts

private let sideMenuRecentsFontSize = CGFloat(12)

struct SidebarView: View {
    @ObservedObject var helperModelSettings: LLMModelSettings
    @ObservedObject var chatSessions: ChatSessionStore
    var onInsertPluginPrefix: ((String) -> Void)?
    /// Reference type must not be recreated every `View` value; hold via `@State`.
    @State private var helperModelSettingsPanelController = LLMModelSettingsPanelController()
    @ObservedObject private var softwareFactory = SoftwareFactorySettingsService.shared
    @ObservedObject private var pluginList = PluginListStore.shared
    @State private var sampleInstallMessage: String?
    @State private var expandedPluginIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "building.columns")
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundStyle(Color(red: 0.176, green: 0.286, blue: 0.576))
                    Text("derrick")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                }

                Spacer()

                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                Image(systemName: "sidebar.left")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 18)

            VStack(alignment: .leading, spacing: 10) {
                SidebarActionRow(
                    row: SidebarRow(id: "new-chat", icon: "plus.circle.fill", title: "New chat", isProminent: true)
                ) {
                    chatSessions.openNewChat()
                }
                SidebarActionRow(
                    row: SidebarRow(id: "chats", icon: "message.fill", title: "Chats")
                )
                if softwareFactory.isEnabled {
                    SidebarActionRow(
                        row: SidebarRow(
                            id: "software-factory",
                            icon: "hammer.fill",
                            title: "Software Factory",
                            isProminent: chatSessions.isFactorySessionSelected
                        )
                    ) {
                        chatSessions.openFactorySession()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recents")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if chatSessions.recentSessions.isEmpty {
                            Text("No recent chats")
                                .font(.system(size: sideMenuRecentsFontSize))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(chatSessions.recentSessions) { session in
                                Button {
                                    chatSessions.selectSession(id: session.sessionID)
                                } label: {
                                    Text(session.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                                         ? session.title!
                                         : "Chat")
                                        .font(.system(size: sideMenuRecentsFontSize))
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .foregroundStyle(
                                            chatSessions.selectedSessionID == session.sessionID
                                                ? Color.primary
                                                : Color.primary.opacity(0.9)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if softwareFactory.isEnabled || !pluginList.plugins.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Plugins")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if softwareFactory.isEnabled {
                            Button("Install daily news") {
                                Task {
                                    sampleInstallMessage = await pluginList.installDailyNewsSample()
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    if pluginList.plugins.isEmpty {
                        Text("No installed plugins")
                            .font(.system(size: sideMenuRecentsFontSize))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(pluginList.plugins) { plugin in
                            pluginRow(plugin)
                        }
                    }
                    if let message = sampleInstallMessage ?? pluginList.lastActionMessage, !message.isEmpty {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Button {
                helperModelSettingsPanelController.show(helperModelSettings: helperModelSettings)
            } label: {
                HStack {
                    Circle()
                        .fill(.black.opacity(0.8))
                        .frame(width: 40, height: 40)
                        .overlay(Text("D").foregroundStyle(.white))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("dave")
                        Text("Free plan")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .background(Color(red: 248.0/255.0, green: 248.0/255.0, blue: 246.0/255.0))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.black.opacity(0.08))
                .frame(width: 1)
        }
        .task {
            await pluginList.reload()
        }
    }

    @ViewBuilder
    private func pluginRow(_ plugin: PluginSidebarItem) -> some View {
        let expanded = expandedPluginIDs.contains(plugin.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    if expanded {
                        expandedPluginIDs.remove(plugin.id)
                    } else {
                        expandedPluginIDs.insert(plugin.id)
                    }
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 10, height: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(plugin.id)
                                    .font(.system(size: sideMenuRecentsFontSize))
                                    .lineLimit(1)
                                if !plugin.version.isEmpty {
                                    Text(plugin.version)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if !plugin.description.isEmpty {
                                Text(plugin.description)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)
                Button {
                    chatSessions.openFactorySession(editing: plugin.id)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Change \(plugin.id)")
                Button {
                    onInsertPluginPrefix?("/\(plugin.id)")
                } label: {
                    Text("/")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Insert /\(plugin.id) into the prompt")
                .disabled(!plugin.enabled)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { plugin.enabled },
                        set: { newValue in
                            Task { await pluginList.setEnabled(id: plugin.id, enabled: newValue) }
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            if expanded {
                ForEach(plugin.versions) { version in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(version.version)
                                    .font(.system(size: sideMenuRecentsFontSize, design: .monospaced))
                                if version.isCurrent {
                                    Text("current")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                } else if !version.status.isEmpty {
                                    Text(version.status)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 16)
                        Button {
                            pluginList.pendingVersionDelete = PendingPluginVersionDelete(
                                version: version,
                                pluginID: plugin.id
                            )
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Delete version \(version.version)")
                    }
                }
            }
        }
    }

}

#Preview {
    let config = DBRepositoryConfiguration(
        applicationName: "preview",
        databaseName: "preview",
        databaseDirectoryURL: FileManager.default.temporaryDirectory,
        username: "ui",
        password: "ui"
    )
    let store = ChatSessionStore()
    SidebarView(
        helperModelSettings: LLMModelSettings(repository: DBRepository(configuration: config)),
        chatSessions: store
    )
}

private enum PluginDeleteConfirmFocus: Hashable {
    case delete
    case cancel
}

struct PluginDeleteConfirmFooter: View {
    var onCancel: () -> Void
    var onDelete: () -> Void
    @FocusState private var focused: PluginDeleteConfirmFocus?

    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Button("Cancel", action: onCancel)
                .buttonStyle(ModalSecondaryButtonStyle())
                .focusable()
                .focused($focused, equals: .cancel)
                .keyboardShortcut(.cancelAction)
            Button("Delete", action: onDelete)
                .buttonStyle(ModalPrimaryButtonStyle())
                .focusable()
                .focused($focused, equals: .delete)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .padding(.top, 4)
        .defaultFocus($focused, .delete)
        .onAppear { focused = .delete }
        .onKeyPress(.return) {
            if focused == .cancel {
                onCancel()
            } else {
                onDelete()
            }
            return .handled
        }
        .onKeyPress(.space) {
            if focused == .cancel {
                onCancel()
            } else {
                onDelete()
            }
            return .handled
        }
    }
}

struct SidebarRow: Identifiable, Hashable, Sendable {
    let id: String
    let icon: String
    let title: String
    let isProminent: Bool
    let isDisabled: Bool

    init(id: String, icon: String, title: String, isProminent: Bool = false, isDisabled: Bool = false) {
        self.id = id
        self.icon = icon
        self.title = title
        self.isProminent = isProminent
        self.isDisabled = isDisabled
    }
}

struct SidebarActionRow: View {
    let row: SidebarRow
    var action: (() -> Void)?

    init(row: SidebarRow, action: (() -> Void)? = nil) {
        self.row = row
        self.action = action
    }

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: row.icon)
                    .frame(width: 18)
                    .foregroundStyle(row.isDisabled ? Color.secondary.opacity(0.5) : Color.primary)

                Text(row.title)
                    .foregroundStyle(row.isDisabled ? Color.secondary.opacity(0.5) : Color.primary)

                if row.isProminent {
                    Spacer()
                }
            }
            .font(.callout)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(row.isProminent ? Color.black.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(row.isDisabled || action == nil)
    }
}
