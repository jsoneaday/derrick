import SwiftUI

public enum HostUITextStyle: String, Sendable, Hashable {
    case title
    case body
    case callout
    case caption
}

public struct HostUIText: View {
    private let value: String
    private let style: HostUITextStyle
    private let multilineCenter: Bool

    public init(
        _ value: String,
        style: HostUITextStyle = .body,
        multilineCenter: Bool = false
    ) {
        self.value = value
        self.style = style
        self.multilineCenter = multilineCenter
    }

    public var body: some View {
        Text(value)
            .font(font)
            .foregroundStyle(foreground)
            .multilineTextAlignment(multilineCenter ? .center : .leading)
            .frame(
                maxWidth: multilineCenter ? 460 : .infinity,
                alignment: multilineCenter ? .center : .leading
            )
    }

    private var font: Font {
        switch style {
        case .title:
            return .system(size: 28, weight: .semibold, design: .rounded)
        case .body:
            return .body
        case .callout:
            return .callout
        case .caption:
            return .caption
        }
    }

    private var foreground: some ShapeStyle {
        switch style {
        case .title, .body:
            return AnyShapeStyle(.primary)
        case .callout, .caption:
            return AnyShapeStyle(.secondary)
        }
    }
}
