import SwiftUI

struct ChatTabBarView: View {
    @ObservedObject var store: ChatSessionStore

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

    private func browserTab(_ tab: ChatTab) -> some View {
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
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                }
                .frame(maxWidth: 200, alignment: .leading)
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
            TabShape(cornerRadius: tabCorner)
                .fill(isSelected ? selectedFill : Color.primary.opacity(0.03))
        }
        // Sit on top of the strip hairline so the selected tab merges into the pane.
        .padding(.bottom, isSelected ? -1 : 0)
        .zIndex(isSelected ? 1 : 0)
    }
}

/// Browser-style tab: rounded on the top only.
private struct TabShape: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(cornerRadius, rect.height / 2, rect.width / 2)
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + r, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + r),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
