import Foundation
import UniformTypeIdentifiers

struct ChatFileAttachment: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let originalFilename: String
    let byteCount: Int64
    let typeIdentifier: String
    let stagedRelativePath: String

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

enum ChatFileAttachmentPolicy {
    static let maximumFileCount = 5
    static let maximumBytesPerFile: Int64 = 25 * 1024 * 1024
    static let maximumInlineUTF8Bytes = 200_000

    static let deniedExtensions: Set<String> = [
        "sh", "bash", "zsh", "csh", "ksh", "command", "tool",
        "app", "dmg", "pkg", "mpkg", "exe", "bat", "cmd", "com",
        "dylib", "so", "bundle",
    ]

    static let allowedExtensions: Set<String> = [
        "csv", "tsv", "txt", "md", "markdown", "json", "html", "htm", "xml",
        "pdf", "xlsx", "xls", "docx", "rtf",
    ]

    static let inlineableExtensions: Set<String> = [
        "csv", "tsv", "txt", "md", "markdown", "json", "html", "htm", "xml",
    ]

    static var allowedContentTypes: [UTType] {
        var types: [UTType] = [
            .pdf,
            .plainText,
            .utf8PlainText,
            .commaSeparatedText,
            .tabSeparatedText,
            .json,
            .html,
            .xml,
            .rtf,
        ]
        for ext in ["md", "markdown", "xlsx", "xls", "docx"] {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }

    private static let deniedContentTypes: [UTType] = {
        var types: [UTType] = [
            .executable,
            .unixExecutable,
            .application,
            .applicationBundle,
            .diskImage,
            .package,
            .directory,
        ]
        if let shell = UTType("public.shell-script") {
            types.append(shell)
        }
        return types
    }()

    private static let inlineableContentTypes: [UTType] = [
        .plainText,
        .utf8PlainText,
        .commaSeparatedText,
        .tabSeparatedText,
        .json,
        .html,
        .xml,
    ]

    static func isDenied(_ type: UTType) -> Bool {
        deniedContentTypes.contains { type.conforms(to: $0) }
    }

    static func isAllowed(filename: String, type: UTType?) -> Bool {
        let ext = filenameExtension(filename)
        if deniedExtensions.contains(ext) {
            return false
        }
        if let type, isDenied(type) {
            return false
        }
        if let type, allowedContentTypes.contains(where: { type.conforms(to: $0) }) {
            return true
        }
        return allowedExtensions.contains(ext)
    }

    static func isInlineable(filename: String, typeIdentifier: String, byteCount: Int64) -> Bool {
        guard byteCount > 0, byteCount <= Int64(maximumInlineUTF8Bytes) else {
            return false
        }
        if inlineableExtensions.contains(filenameExtension(filename)) {
            return true
        }
        guard let type = UTType(typeIdentifier) else {
            return false
        }
        return inlineableContentTypes.contains { type.conforms(to: $0) }
    }

    static func filenameExtension(_ filename: String) -> String {
        URL(fileURLWithPath: filename).pathExtension.lowercased()
    }
}

enum ChatFileAttachmentError: Error, LocalizedError, Equatable {
    case missingSession
    case notAFile(filename: String)
    case typeNotAllowed(filename: String)
    case fileTooLarge(filename: String, byteCount: Int64)
    case tooManyFiles(limit: Int)
    case unreadable(filename: String)

    var errorDescription: String? {
        switch self {
        case .missingSession:
            return "Open a chat before attaching files."
        case .notAFile(let filename):
            return "\(filename) is a folder. Choose files only."
        case .typeNotAllowed(let filename):
            return "\(filename) is not an allowed file type."
        case .fileTooLarge(let filename, let byteCount):
            let size = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
            let limit = ByteCountFormatter.string(
                fromByteCount: ChatFileAttachmentPolicy.maximumBytesPerFile,
                countStyle: .file
            )
            return "\(filename) is \(size). Each file must be \(limit) or smaller."
        case .tooManyFiles(let limit):
            return "You can attach up to \(limit) files."
        case .unreadable(let filename):
            return "Derrick could not read \(filename)."
        }
    }
}
