import AppKit
import SwiftUI

public enum HostUIButtonChrome: String, Sendable, Hashable {
    case primary
    case secondary
}

public struct HostUIButton: View {
    private let title: String
    private let systemImage: String?
    private let chrome: HostUIButtonChrome
    private let disabled: Bool
    private let action: () -> Void

    public init(
        _ title: String,
        systemImage: String? = nil,
        chrome: HostUIButtonChrome = .primary,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.chrome = chrome
        self.disabled = disabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .modifier(HostUIButtonChromeModifier(chrome: chrome))
    }
}

private struct HostUIButtonChromeModifier: ViewModifier {
    let chrome: HostUIButtonChrome

    func body(content: Content) -> some View {
        switch chrome {
        case .primary:
            content
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .labelColor).opacity(0.85))
                )
        case .secondary:
            content
                .foregroundStyle(.primary)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                )
        }
    }
}

public struct HostUIText: View {
    private let text: String
    private let font: Font

    public init(_ text: String, font: Font = .body) {
        self.text = text
        self.font = font
    }

    public var body: some View {
        Text(text)
            .font(font)
            .textSelection(.enabled)
    }
}

public struct HostUITextField: View {
    @Binding private var text: String
    private let placeholder: String

    public init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    public var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
    }
}

public struct HostUIScreen<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

public struct HostUISidebar<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .frame(minWidth: 300, idealWidth: 360, maxWidth: 440)
            .frame(maxHeight: .infinity, alignment: .topLeading)
    }
}

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
                    .font(.headline)
            }
            content
        }
    }
}
