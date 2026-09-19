import SwiftUI

public struct HostUITabItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var unreadCount: Int
    public var muted: Bool

    public init(id: String, title: String, unreadCount: Int = 0, muted: Bool = false) {
        self.id = id
        self.title = title
        self.unreadCount = unreadCount
        self.muted = muted
    }
}

public struct HostUITabStrip: View {
    private let tabs: [HostUITabItem]
    private let selectedID: String?
    private let onSelect: (String) -> Void

    private let stripColor = Color(red: 236.0 / 255.0, green: 236.0 / 255.0, blue: 233.0 / 255.0)
    private let selectedFill = Color(red: 248.0 / 255.0, green: 248.0 / 255.0, blue: 246.0 / 255.0)
    private let tabCorner: CGFloat = 8

    public init(
        tabs: [HostUITabItem],
        selectedID: String?,
        onSelect: @escaping (String) -> Void
    ) {
        self.tabs = tabs
        self.selectedID = selectedID
        self.onSelect = onSelect
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(tabs) { tab in
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

    private func browserTab(_ tab: HostUITabItem) -> some View {
        let isSelected = selectedID == tab.id
        return Button {
            onSelect(tab.id)
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
                    Text(tab.unreadCount > 99 ? "99+" : "\(tab.unreadCount)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                }
            }
            .frame(maxWidth: 220, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 9)
            .background {
                HostUIBrowserTabShape(cornerRadius: tabCorner)
                    .fill(isSelected ? selectedFill : Color.primary.opacity(0.03))
            }
        }
        .buttonStyle(.plain)
        .padding(.bottom, isSelected ? -1 : 0)
        .zIndex(isSelected ? 1 : 0)
    }
}

/// Browser-style tab outline used by `HostUITabStrip`.
public struct HostUIBrowserTabShape: Shape {
    public var cornerRadius: CGFloat

    public init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
    }

    public func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, rect.height / 2, rect.width / 2)
        var path = Path()
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
