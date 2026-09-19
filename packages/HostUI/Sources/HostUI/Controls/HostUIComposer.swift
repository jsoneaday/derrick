import SwiftUI

public struct HostUIComposer: View {
    private let placeholder: String
    private let sendTitle: String
    private let isSending: Bool
    private let canSend: Bool
    @Binding private var text: String
    private let onSend: () -> Void

    public init(
        placeholder: String = "Message",
        sendTitle: String = "Send",
        text: Binding<String>,
        isSending: Bool = false,
        canSend: Bool = true,
        onSend: @escaping () -> Void
    ) {
        self.placeholder = placeholder
        self.sendTitle = sendTitle
        self._text = text
        self.isSending = isSending
        self.canSend = canSend
        self.onSend = onSend
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HostUITextField(
                placeholder: placeholder,
                text: $text,
                axis: .vertical
            )
            HStack {
                Spacer()
                HostUIButton(
                    isSending ? "Sending…" : sendTitle,
                    systemImage: "paperplane.fill",
                    disabled: !canSend || isSending,
                    action: onSend
                )
            }
        }
    }
}
