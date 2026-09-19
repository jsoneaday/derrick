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
        Group {
            if chrome == .primary {
                button.buttonStyle(HostUIPrimaryButtonStyle())
            } else {
                button.buttonStyle(HostUISecondaryButtonStyle())
            }
        }
        .disabled(disabled)
    }

    private var button: some View {
        Button(action: action) {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
    }
}
