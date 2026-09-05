import Foundation
import Structure
import UniformTypeIdentifiers

struct ChatFileAttachmentStager: Sendable {
    let rootDirectory: URL
    var maximumFileCount: Int
    var maximumBytesPerFile: Int64

    init(
        rootDirectory: URL,
        maximumFileCount: Int = ChatFileAttachmentPolicy.maximumFileCount,
        maximumBytesPerFile: Int64 = ChatFileAttachmentPolicy.maximumBytesPerFile
    ) {
        self.rootDirectory = rootDirectory
        self.maximumFileCount = maximumFileCount
        self.maximumBytesPerFile = maximumBytesPerFile
    }

    init() throws {
        try self.init(rootDirectory: Self.defaultRootDirectory())
    }

    static func defaultRootDirectory() throws -> URL {
        try DerrickFilePaths.attachmentsRoot()
    }

    func stage(
        urls: [URL],
        sessionID: String,
        existingCount: Int
    ) throws -> [ChatFileAttachment] {
        let trimmedSession = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSession.isEmpty else {
            throw ChatFileAttachmentError.missingSession
        }
        let sessionKey = DerrickFilePaths.sanitizedPathComponent(trimmedSession)
        guard existingCount + urls.count <= maximumFileCount else {
            throw ChatFileAttachmentError.tooManyFiles(limit: maximumFileCount)
        }

        var staged: [ChatFileAttachment] = []
        do {
            for url in urls {
                staged.append(try stageOne(url: url, sessionID: sessionKey))
            }
        } catch {
            for item in staged {
                remove(item)
            }
            throw error
        }
        return staged
    }

    func remove(_ attachment: ChatFileAttachment) {
        let folder = rootDirectory
            .appendingPathComponent(attachment.stagedRelativePath)
            .deletingLastPathComponent()
        try? FileManager.default.removeItem(at: folder)
    }

    private func stageOne(url: URL, sessionID: String) throws -> ChatFileAttachment {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let filename = url.lastPathComponent
        guard !filename.isEmpty else {
            throw ChatFileAttachmentError.unreadable(filename: "file")
        }

        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .fileSizeKey,
            .contentTypeKey,
        ])
        if values.isDirectory == true {
            throw ChatFileAttachmentError.notAFile(filename: filename)
        }

        let type = values.contentType
        guard ChatFileAttachmentPolicy.isAllowed(filename: filename, type: type) else {
            throw ChatFileAttachmentError.typeNotAllowed(filename: filename)
        }

        let byteCount = try fileSize(url: url, resourceSize: values.fileSize)
        guard byteCount <= maximumBytesPerFile else {
            throw ChatFileAttachmentError.fileTooLarge(filename: filename, byteCount: byteCount)
        }

        let attachmentID = UUID().uuidString
        let safeName = Self.sanitizedFilename(filename)
        let relativePath = "\(sessionID)/\(attachmentID)/\(safeName)"
        let destination = rootDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            throw ChatFileAttachmentError.unreadable(filename: filename)
        }

        return ChatFileAttachment(
            id: attachmentID,
            originalFilename: filename,
            byteCount: byteCount,
            typeIdentifier: type?.identifier ?? UTType.data.identifier,
            stagedRelativePath: relativePath
        )
    }

    private func fileSize(url: URL, resourceSize: Int?) throws -> Int64 {
        if let resourceSize {
            return Int64(resourceSize)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber {
            return size.int64Value
        }
        throw ChatFileAttachmentError.unreadable(filename: url.lastPathComponent)
    }

    static func sanitizedFilename(_ name: String) -> String {
        let base = URL(fileURLWithPath: name).lastPathComponent
        return sanitizedPathComponent(base)
    }

    static func sanitizedPathComponent(_ raw: String) -> String {
        DerrickFilePaths.sanitizedPathComponent(raw)
    }
}
