import Foundation

struct ChatFileAttachmentInlinePayload: Hashable, Sendable {
    let attachment: ChatFileAttachment
    let utf8Text: String?
}

enum ChatFileAttachmentInliner {
    static func payloads(
        attachments: [ChatFileAttachment],
        rootDirectory: URL?
    ) -> [ChatFileAttachmentInlinePayload] {
        attachments.map { attachment in
            ChatFileAttachmentInlinePayload(
                attachment: attachment,
                utf8Text: inlineText(for: attachment, rootDirectory: rootDirectory)
            )
        }
    }

    private static func inlineText(
        for attachment: ChatFileAttachment,
        rootDirectory: URL?
    ) -> String? {
        guard ChatFileAttachmentPolicy.isInlineable(
            filename: attachment.originalFilename,
            typeIdentifier: attachment.typeIdentifier,
            byteCount: attachment.byteCount
        ) else {
            return nil
        }
        guard let rootDirectory else {
            return nil
        }
        let url = rootDirectory.appendingPathComponent(attachment.stagedRelativePath)
        guard let data = try? Data(contentsOf: url),
              data.count <= ChatFileAttachmentPolicy.maximumInlineUTF8Bytes,
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text
    }
}

enum ChatFileAttachmentPromptComposer {
    static let emptyUserFallback = "Process the attached files."

    static func agentPrompt(
        userText: String,
        payloads: [ChatFileAttachmentInlinePayload]
    ) -> String {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payloads.isEmpty else {
            return trimmed
        }

        var lines: [String] = []
        lines.append(trimmed.isEmpty ? emptyUserFallback : trimmed)
        lines.append("")
        lines.append("Attached files:")
        for (index, payload) in payloads.enumerated() {
            let attachment = payload.attachment
            let name = attachment.originalFilename
            let size = attachment.displaySize
            if let text = payload.utf8Text {
                lines.append("\(index + 1). \(name) (\(size))")
                lines.append("----- begin \(name) -----")
                lines.append(text)
                lines.append("----- end \(name) -----")
            } else {
                lines.append(
                    "\(index + 1). \(name) (\(size)) — contents are not included in this message. The file is staged on this Mac. Call files.extract to extract or convert it."
                )
            }
        }
        return lines.joined(separator: "\n")
    }
}
