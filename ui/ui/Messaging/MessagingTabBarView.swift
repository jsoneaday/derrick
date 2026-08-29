import SwiftUI

struct MessagingTabBarView: View {
    @ObservedObject var store: MessagingStore

    private let stripColor = Color(red: 236.0 / 255.0, green: 236.0 / 255.0, blue: 233.0 / 255.0)
    private let selectedFill = Color(red: 248.0 / 255.0, green: 248.0 / 255.0, blue: 246.0 / 255.0)
    private let tabCorner: CGFloat = 8

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(store.tabs) { tab in
                    browserTab(tab)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .background(stripColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }

    private func browserTab(_ tab: MessagingTab) -> some View {
        let isSelected = store.selectedThreadID == tab.id
        return HStack(spacing: 6) {
            Button {
                Task { await store.selectThread(id: tab.id) }
            } label: {
                HStack(spacing: 6) {
                    if tab.muted {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(tab.title)
                        .lineLimit(1)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    if tab.unreadCount > 0 {
                        MessagingUnreadBadge(count: tab.unreadCount)
                    }
                }
                .frame(maxWidth: 220, alignment: .leading)
            }
            .buttonStyle(.plain)

            if store.tabs.count > 1 {
                Button {
                    store.closeTab(id: tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close tab")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.top, 8)
        .padding(.bottom, 9)
        .background {
            BrowserTabShape(cornerRadius: tabCorner)
                .fill(isSelected ? selectedFill : Color.primary.opacity(0.03))
        }
        .padding(.bottom, isSelected ? -1 : 0)
        .zIndex(isSelected ? 1 : 0)
    }
}

struct MessagingUnreadBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.accentColor, in: Capsule())
    }
}
