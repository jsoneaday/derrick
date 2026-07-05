//
//  SidebarView.swift
//  ui
//
//  Created by David Choi on 7/4/26.
//

import SwiftUI

private let sideMenuRecentsFontSize = CGFloat(12)

struct SidebarView: View {
    private let topActions = [
        SidebarRow(icon: "plus.circle.fill", title: "New chat", isProminent: true),
        SidebarRow(icon: "message.fill", title: "Chats"),
        SidebarRow(icon: "folder.fill", title: "Projects"),
        SidebarRow(icon: "square.grid.2x2.fill", title: "Artifacts"),
        SidebarRow(icon: "chevron.left.forwardslash.chevron.right", title: "Code", isDisabled: true),
        SidebarRow(icon: "briefcase.fill", title: "Customize")
    ]

    private let recents = [
        "React Native desktop adoption",
        "RDS compute charges when idle",
        "Unsupported media type error",
        "React.cache compatibility",
        "AI coding models with flat-rate plans",
        "Next.js fetch retry behavior",
        "Rust SDKs for major LLM vendors"
    ]

    private let starred = [
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
                ForEach(topActions) { row in
                    SidebarActionRow(row: row)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Starred")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(starred, id: \.self) { item in
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
                        ForEach(recents, id: \.self) { recent in
                            Text(recent)
                                .font(.system(size: sideMenuRecentsFontSize))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(.primary.opacity(0.9))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer()

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

struct SidebarRow: Identifiable, Hashable {
    let id = UUID()
    let icon: String
    let title: String
    let isProminent: Bool
    let isDisabled: Bool

    init(icon: String, title: String, isProminent: Bool = false, isDisabled: Bool = false) {
        self.icon = icon
        self.title = title
        self.isProminent = isProminent
        self.isDisabled = isDisabled
    }
}

struct SidebarActionRow: View {
    let row: SidebarRow

    var body: some View {
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
}
