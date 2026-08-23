import AppKit
import UniformTypeIdentifiers

enum ChatFileAttachmentPicker {
    @MainActor
    static func pickFiles() async -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.allowedContentTypes = ChatFileAttachmentPolicy.allowedContentTypes
        panel.title = "Attach files"
        panel.message = "Choose up to \(ChatFileAttachmentPolicy.maximumFileCount) files."
        panel.prompt = "Attach"

        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK else {
            return []
        }
        return panel.urls
    }
}
