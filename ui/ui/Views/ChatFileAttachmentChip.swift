import SwiftUI

struct ChatFileAttachmentChipBar: View {
    let attachments: [ChatFileAttachment]
    var onRemove: ((ChatFileAttachment) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ChatFileAttachmentChip(
                        attachment: attachment,
                        onRemove: onRemove
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attached files")
    }
}

private struct ChatFileAttachmentChip: View {
    let attachment: ChatFileAttachment
    var onRemove: ((ChatFileAttachment) -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc")
                .font(.system(size: 11, weight: .medium))
            Text(attachment.originalFilename)
                .font(.system(size: 12))
                .lineLimit(1)
            Text(attachment.displaySize)
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            if let onRemove {
                Button {
                    onRemove(attachment)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(attachment.originalFilename)")
            }
        }
        .foregroundStyle(Color(nsColor: .labelColor))
        .padding(.leading, 10)
        .padding(.trailing, onRemove == nil ? 10 : 6)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.04), in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .help("\(attachment.originalFilename) (\(attachment.displaySize))")
        .accessibilityLabel("\(attachment.originalFilename), \(attachment.displaySize)")
    }
}
