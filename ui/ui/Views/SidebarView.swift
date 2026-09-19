import SwiftUI
import DBRepository
import Structure

private let sideMenuRecentsFontSize = CGFloat(12)

struct SidebarView: View {
    @ObservedObject var helperModelSettings: LLMModelSettings
    @ObservedObject var modelThinkingSettings: LLMModelThinkingSettings
    @ObservedObject var chatSessions: ChatSessionStore
    @ObservedObject var messaging: MessagingStore
    @Binding var workspace: AppWorkspace
    var isDebugEnabled: Bool = false
    /// Reference type must not be recreated every `View` value; hold via `@State`.
    @State private var helperModelSettingsPanelController = LLMModelSettingsPanelController()
    @ObservedObject private var pluginFactoryList = PluginFactoryListStore.shared

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
                    row: SidebarPrimaryActions.newChat
                ) {
                    workspace = .chats
                    chatSessions.openNewChat()
                }

                pluginsSection

                SidebarActionRow(
                    row: SidebarRow(
                        id: "chats",
                        icon: "message.fill",
                        title: "Chat",
                        isProminent: workspace == .chats
                    )
                ) {
                    workspace = .chats
                }
                if isDebugEnabled {
                    SidebarActionRow(
                        row: SidebarRow(
                            id: "debug-logs",
                            icon: "ladybug.fill",
                            title: "Debug Logs",
                            isProminent: workspace == .debugLogs
                        )
                    ) {
                        workspace = .debugLogs
                    }
                }
            }

            if workspace == .debugLogs {
                debugLogsHint
            }
            recentsList

            Spacer()

            Button {
                helperModelSettingsPanelController.show(
                    helperModelSettings: helperModelSettings,
                    modelThinkingSettings: modelThinkingSettings
                )
            } label: {
                HStack {
                    Circle()
                        .fill(.black.opacity(0.8))
                        .frame(width: 40, height: 40)
                        .overlay(Text("D").foregroundStyle(.white))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Account")
                        Text("Local")
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
            await pluginFactoryList.reload()
            await messaging.syncConnectorsFromFactory()
        }
        .onChange(of: chatSessions.selectedTab?.turns.count ?? 0) { _, _ in
            Task {
                await pluginFactoryList.reload()
                await messaging.syncConnectorsFromFactory()
            }
        }
        .onChange(of: chatSessions.isSelectedTabStreaming) { _, isStreaming in
            guard !isStreaming else { return }
            Task {
                await pluginFactoryList.reload()
                await messaging.syncConnectorsFromFactory()
            }
        }
    }

    private var pluginsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Parent is not navigational — Create and List do the work.
            SidebarActionRow(
                row: SidebarRow(
                    id: SidebarPrimaryActions.plugins.id,
                    icon: SidebarPrimaryActions.plugins.icon,
                    title: SidebarPrimaryActions.plugins.title,
                    isProminent: workspace.isPluginsSection
                )
            )
            SidebarActionRow(
                row: SidebarRow(
                    id: SidebarPrimaryActions.pluginsCreate.id,
                    icon: SidebarPrimaryActions.pluginsCreate.icon,
                    title: SidebarPrimaryActions.pluginsCreate.title,
                    isProminent: workspace == .pluginsCreate
                ),
                indented: true
            ) {
                NotificationCenter.default.post(
                    name: ChatShellNotification.startPluginCreation,
                    object: nil
                )
            }
            SidebarActionRow(
                row: SidebarRow(
                    id: SidebarPrimaryActions.pluginsList.id,
                    icon: SidebarPrimaryActions.pluginsList.icon,
                    title: SidebarPrimaryActions.pluginsList.title,
                    isProminent: workspace == .pluginsList
                ),
                indented: true
            ) {
                NotificationCenter.default.post(
                    name: ChatShellNotification.openPluginList,
                    object: nil
                )
            }
        }
    }

    private var debugLogsHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Diagnostics")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Logs are stored in the local database and include UI, daemon, agent, MCP, and connector activity.")
                .font(.system(size: sideMenuRecentsFontSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private var recentsList: some View {
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
                                openRecent(session)
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
    }

    private func openRecent(_ session: ChatSessionDTO) {
        let isCreator = session.metadata["pluginCreator"] == "true"
            || PluginSpecProcession.isCreatorTabID(session.sessionID)
        let started = session.metadata["pluginCreatorStarted"] == "true"
        if isCreator, !started {
            // Unstarted Create screens are not sessions — open a fresh in-memory Create instead.
            NotificationCenter.default.post(
                name: ChatShellNotification.startPluginCreation,
                object: nil
            )
            return
        }
        if isCreator {
            workspace = .pluginsCreate
        } else {
            workspace = .chats
        }
        chatSessions.selectSession(id: session.sessionID)
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
    let repo = DBRepository(configuration: config)
    SidebarView(
        helperModelSettings: LLMModelSettings(repository: repo),
        modelThinkingSettings: LLMModelThinkingSettings(repository: repo),
        chatSessions: store,
        messaging: MessagingStore(),
        workspace: .constant(.chats)
    )
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

enum SidebarPrimaryActions {
    static let newChat = SidebarRow(id: "new-chat", icon: "plus.circle.fill", title: "New chat")
    static let plugins = SidebarRow(id: "plugins", icon: "puzzlepiece.extension.fill", title: "Plugins")
    static let pluginsCreate = SidebarRow(id: "plugins-create", icon: "plus.square", title: "Create")
    static let pluginsList = SidebarRow(id: "plugins-list", icon: "list.bullet", title: "List")
    /// Kept for older tests / settings that still refer to the former single Plugins row.
    static let newPlugin = plugins
}

struct SidebarActionRow: View {
    let row: SidebarRow
    var indented: Bool = false
    var action: (() -> Void)?

    init(row: SidebarRow, indented: Bool = false, action: (() -> Void)? = nil) {
        self.row = row
        self.indented = indented
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
            .padding(.leading, indented ? 28 : 10)
            .padding(.trailing, 10)
            .background(row.isProminent ? Color.black.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(row.isDisabled || action == nil)
        .accessibilityIdentifier("sidebar-\(row.id)")
        .accessibilityLabel(row.title)
    }
}
