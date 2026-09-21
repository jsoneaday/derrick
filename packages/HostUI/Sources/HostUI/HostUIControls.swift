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
        let label = HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
        }
        let button = Button(action: action) { label }
            .disabled(disabled)
            .opacity(disabled ? 0.45 : 1)
        switch chrome {
        case .primary:
            button.buttonStyle(HostUIPrimaryButtonStyle())
        case .secondary:
            button.buttonStyle(HostUISecondaryButtonStyle())
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

public enum HostUITextFieldChrome: String, Sendable, Hashable {
    /// Bordered field for forms and catalog `text_field`.
    case form
    /// Borderless field inside composer chrome.
    case plain
}

public struct HostUITextField: View {
    @Binding private var text: String
    private let placeholder: String
    private let axis: Axis?
    private let chrome: HostUITextFieldChrome

    public init(
        _ placeholder: String,
        text: Binding<String>,
        axis: Axis? = nil,
        chrome: HostUITextFieldChrome = .form
    ) {
        self.placeholder = placeholder
        self._text = text
        self.axis = axis
        self.chrome = chrome
    }

    /// Labeled form-style field used by composers and factory forms.
    public init(
        placeholder: String,
        text: Binding<String>,
        axis: Axis? = nil,
        chrome: HostUITextFieldChrome = .form
    ) {
        self.placeholder = placeholder
        self._text = text
        self.axis = axis
        self.chrome = chrome
    }

    public var body: some View {
        field
            .textFieldStyle(.plain)
            .modifier(HostUITextFieldChromeModifier(chrome: chrome, axis: axis))
    }

    @ViewBuilder
    private var field: some View {
        if let axis {
            TextField(placeholder, text: $text, axis: axis)
                .lineLimit(1...6)
        } else {
            TextField(placeholder, text: $text)
        }
    }
}

private struct HostUITextFieldChromeModifier: ViewModifier {
    let chrome: HostUITextFieldChrome
    let axis: Axis?

    func body(content: Content) -> some View {
        switch chrome {
        case .plain:
            content
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .background(.clear)
        case .form:
            content
                .padding(.horizontal, axis == .vertical ? 14 : 12)
                .padding(.vertical, axis == .vertical ? 12 : 8)
                .background(
                    RoundedRectangle(
                        cornerRadius: axis == .vertical ? 14 : 10,
                        style: .continuous
                    )
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
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
            .frame(maxHeight: .infinity, alignment: .top)
            .containerRelativeFrame(.horizontal) { width, _ in
                HostUIMessagingLayout.sidebarWidth(forContainer: width)
            }
            .clipped()
    }
}

/// Publishes the pane width so gutters and padding track the channel or thread, not a point lock.
struct HostUIPaneWidthReader<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geo in
            content()
                .environment(\.hostUIPaneWidth, geo.size.width)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }
}

extension EnvironmentValues {
    /// Width of the current HostUI channel or thread column.
    @Entry var hostUIPaneWidth: CGFloat = 720
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
