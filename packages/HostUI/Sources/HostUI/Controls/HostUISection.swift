import SwiftUI

public struct HostUISection<Content: View>: View {
    private let title: String?
    private let content: Content

    public init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
