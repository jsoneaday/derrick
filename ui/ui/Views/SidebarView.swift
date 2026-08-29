import SwiftUI
import DBRepository
import Plugin
import ServiceContracts

private let sideMenuRecentsFontSize = CGFloat(12)

struct SidebarView: View {
    @ObservedObject var helperModelSettings: LLMModelSettings
    @ObservedObject var chatSessions: ChatSessionStore
    @ObservedObject var messaging: MessagingStore
    @Binding var workspace: AppWorkspace
    /// Reference type must not be recreated every `View` value; hold via `@State`.
    @State private var helperModelSettingsPanelController = LLMModelSettingsPanelController()
    @ObservedObject private var pluginFactoryList = PluginFactoryListStore.shared
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
                    row: SidebarRow(id: "new-chat", icon: "plus.circle.fill", title: "New chat")
                ) {
                    workspace = .chats
                    chatSessions.openNewChat()
                }
                SidebarActionRow(
                    row: SidebarRow(
                        id: "chats",
                        icon: "message.fill",
                        title: "Chats",
                        isProminent: workspace == .chats
                    )
                ) {
                    workspace = .chats
                }
                SidebarActionRow(
                    row: SidebarRow(
                        id: "plugins",
                        icon: "puzzlepiece.extension.fill",
                        title: "Plugins",
                        isProminent: workspace == .plugins
                    )
                ) {
                    workspace = .plugins
                    Task {
                        await pluginFactoryList.reload()
                        await messaging.syncConnectorsFromFactory()
                    }
                }
                SidebarActionRow(
                    row: SidebarRow(
                        id: "messaging",
                        icon: "bubble.left.and.bubble.right.fill",
                        title: "Messaging",
                        isProminent: workspace == .messaging
                    )
                ) {
                    workspace = .messaging
                    Task { await messaging.syncConnectorsFromFactory() }
                }
            }

            if workspace == .plugins {
                pluginsList
            } else if workspace == .messaging {
                messagingList
            } else {
                recentsList
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
            await pluginFactoryList.reload()
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
                                workspace = .chats
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
    }

    private var messagingList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Connectors")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, 4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if messaging.connectors.isEmpty {
                        Text("No messaging connectors yet")
                            .font(.system(size: sideMenuRecentsFontSize))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(messaging.connectors) { connector in
                            VStack(alignment: .leading, spacing: 4) {
                                Button {
                                    workspace = .messaging
                                    Task { await messaging.openConnector(pluginID: connector.pluginID) }
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(connector.displayName)
                                            .font(.system(size: sideMenuRecentsFontSize))
                                            .lineLimit(1)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .foregroundStyle(
                                                messaging.selectedPluginID == connector.pluginID
                                                    ? Color.primary
                                                    : Color.primary.opacity(0.9)
                                            )
                                        let unread = messaging.unreadTotal(for: connector.pluginID)
                                        if unread > 0 {
                                            MessagingUnreadBadge(count: unread)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)

                                if messaging.selectedPluginID == connector.pluginID {
                                    ForEach(messaging.threads) { thread in
                                        Button {
                                            workspace = .messaging
                                            Task { await messaging.selectThread(id: thread.id) }
                                        } label: {
                                            HStack(spacing: 8) {
                                                if thread.muted {
                                                    Image(systemName: "bell.slash")
                                                        .font(.system(size: 9, weight: .semibold))
                                                        .foregroundStyle(.secondary)
                                                }
                                                Text(thread.title)
                                                    .font(.system(size: sideMenuRecentsFontSize))
                                                    .lineLimit(1)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .foregroundStyle(
                                                        messaging.selectedThreadID == thread.id
                                                            ? Color.primary
                                                            : Color.primary.opacity(0.9)
                                                    )
                                                if thread.unreadCount > 0 {
                                                    MessagingUnreadBadge(count: thread.unreadCount)
                                                }
                                            }
                                            .padding(.leading, 16)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    if let error = messaging.lastError {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var pluginsList: some View {
        let systemGroups = pluginFactoryList.groups.filter { $0.latest?.isSystem == true }
        let userGroups = pluginFactoryList.groups.filter { $0.latest?.isSystem != true }

        return VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if pluginFactoryList.releases.isEmpty {
                        Text("No plugins yet")
                            .font(.system(size: sideMenuRecentsFontSize))
                            .foregroundStyle(.secondary)
                    } else {
                        if !systemGroups.isEmpty {
                            pluginSectionTitle("System")
                            pluginGroupRows(systemGroups)
                        }
                        if !userGroups.isEmpty {
                            pluginSectionTitle("User")
                            pluginGroupRows(userGroups)
                        }
                    }
                    if let error = pluginFactoryList.lastError {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func pluginSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }

    @ViewBuilder
    private func pluginGroupRows(_ groups: [PluginFactoryReleaseGroup]) -> some View {
        ForEach(groups) { group in
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    if expandedPluginIDs.contains(group.pluginID) {
                        expandedPluginIDs.remove(group.pluginID)
                    } else {
                        expandedPluginIDs.insert(group.pluginID)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expandedPluginIDs.contains(group.pluginID)
                            ? "chevron.down"
                            : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("/\(group.pluginID)")
                                .font(.system(size: sideMenuRecentsFontSize, design: .monospaced))
                                .lineLimit(1)
                            Text(group.releases.count == 1
                                ? (group.latest?.isSystem == true ? "system" : "v\(group.latest?.version ?? "")")
                                : "\(group.releases.count) versions")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expandedPluginIDs.contains(group.pluginID) {
                    ForEach(group.releases) { release in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(release.isSystem ? "system" : "v\(release.version)")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(release.reviewSummary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if !release.isSystem {
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
                        }
                        .padding(.leading, 18)
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
