import SwiftUI

struct ChatTabBarView: View {
    @ObservedObject var store: ChatSessionStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.tabs) { tab in
                    tabButton(tab)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color.white.opacity(0.55))
    }

    private func tabButton(_ tab: ChatTab) -> some View {
        let isSelected = store.selectedSessionID == tab.id
        return HStack(spacing: 6) {
            Button {
                store.selectSession(id: tab.id)
            } label: {
                HStack(spacing: 6) {
                    if tab.isStreaming {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(tab.title)
                        .lineLimit(1)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    isSelected ? Color.black.opacity(0.08) : Color.clear,
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)

            if store.tabs.count > 1 {
                Button {
                    store.closeTab(id: tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close tab")
            }
        }
        .padding(.trailing, 2)
    }
}
