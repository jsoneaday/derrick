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
    private let axis: Axis?

    public init(_ placeholder: String, text: Binding<String>, axis: Axis? = nil) {
        self.placeholder = placeholder
        self._text = text
        self.axis = axis
    }

    /// Labeled form-style field used by composers and factory forms.
    public init(
        placeholder: String,
        text: Binding<String>,
        axis: Axis? = nil
    ) {
        self.placeholder = placeholder
        self._text = text
        self.axis = axis
    }

    public var body: some View {
        Group {
            if let axis {
                TextField(placeholder, text: $text, axis: axis)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
            } else {
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
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()
    }
}

public struct HostUISelect: View {
    private let options: [HostUITabItem]
    private let selectedID: String?
    private let placeholder: String
    private let onSelect: (String) -> Void

    public init(
        options: [HostUITabItem],
        selectedID: String?,
        placeholder: String = "Choose",
        onSelect: @escaping (String) -> Void
    ) {
        self.options = options
        self.selectedID = selectedID
        self.placeholder = placeholder
        self.onSelect = onSelect
    }

    public var body: some View {
        Menu {
            ForEach(options) { option in
                Button(option.title) {
                    onSelect(option.id)
                }
            }
        } label: {
            HStack {
                Text(options.first { $0.id == selectedID }?.title ?? placeholder)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

public struct HostUITable: View {
    private let rows: [String]

    public init(rows: [String]) {
        self.rows = rows
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if rows.isEmpty {
                Text("No rows")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Text(row)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
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
