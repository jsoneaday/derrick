import SwiftUI

public struct HostUITextField: View {
    private let label: String?
    private let placeholder: String
    private let axis: Axis?
    @Binding private var text: String

    public init(
        label: String? = nil,
        placeholder: String,
        text: Binding<String>,
        axis: Axis? = nil
    ) {
        self.label = label
        self.placeholder = placeholder
        self._text = text
        self.axis = axis
    }

    public var body: some View {
        HostUISection(title: label) {
            if let axis {
                TextField(placeholder, text: $text, axis: axis)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}
