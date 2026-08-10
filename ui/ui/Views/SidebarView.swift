import SwiftUI
import DBRepository
import ServiceContracts

private let sideMenuRecentsFontSize = CGFloat(12)

struct SidebarView: View {
    @ObservedObject var helperModelSettings: LLMModelSettings
    @ObservedObject var chatSessions: ChatSessionStore
    /// Reference type must not be recreated every `View` value; hold via `@State`.
    @State private var helperModelSettingsPanelController = LLMModelSettingsPanelController()

    private static let starred = [
        "Subscribing to GitHub repos in S..."
    ]

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
                SidebarActionRow(
                    row: SidebarRow(id: "projects", icon: "folder.fill", title: "Projects")
                )
                SidebarActionRow(
                    row: SidebarRow(id: "artifacts", icon: "square.grid.2x2.fill", title: "Artifacts")
                )
                SidebarActionRow(
                    row: SidebarRow(id: "code", icon: "chevron.left.forwardslash.chevron.right", title: "Code", isDisabled: true)
                )
                SidebarActionRow(
                    row: SidebarRow(id: "customize", icon: "briefcase.fill", title: "Customize")
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Starred")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Self.starred, id: \.self) { item in
                        Text(item)
                            .font(.system(size: sideMenuRecentsFontSize))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(Color(nsColor: .labelColor))
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
