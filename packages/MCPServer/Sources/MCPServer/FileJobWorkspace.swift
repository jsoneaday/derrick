import Foundation
import Structure

public struct FileJobWorkspace: Sendable {
    public let jobID: String
    public let inputDirectory: URL
    public let outputDirectory: URL
    public let exportDirectory: URL
    public let copiedFilenames: [String]

    public static func prepare(
        sessionID: String,
        requestedFilenames: [String]?,
        attachmentsRoot: URL? = nil,
        jobsRoot: URL? = nil,
        exportsRoot: URL? = nil
    ) throws -> FileJobWorkspace {
        let trimmedSession = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSession.isEmpty else {
            throw FileJobWorkspaceError.missingSession
        }
        let sessionKey = DerrickFilePaths.sanitizedPathComponent(trimmedSession)
        let attachments = try attachmentsRoot ?? DerrickFilePaths.attachmentsRoot()
        let sessionDirectory = attachments.appendingPathComponent(sessionKey, isDirectory: true)
        let discovered = try discoverFiles(in: sessionDirectory)
        guard !discovered.isEmpty else {
            throw FileJobWorkspaceError.noAttachments
        }

        let selected: [(name: String, url: URL)]
        if let requestedFilenames, !requestedFilenames.isEmpty {
            selected = try requestedFilenames.map { name in
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !trimmed.contains("/"),
                      !trimmed.contains("\\"),
                      trimmed != ".",
                      trimmed != ".."
                else {
                    throw FileJobWorkspaceError.unsafeFilename(name)
                }
                let sanitized = DerrickFilePaths.sanitizedPathComponent(trimmed)
                guard let match = discovered.first(where: {
                    $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame
                        || $0.name.compare(sanitized, options: .caseInsensitive) == .orderedSame
                }) else {
                    throw FileJobWorkspaceError.missingFile(trimmed)
                }
                return match
            }
        } else {
            selected = discovered
        }
        guard selected.count <= 5 else {
            throw FileJobWorkspaceError.tooManyFiles
        }

        let jobID = UUID().uuidString.lowercased()
        let jobs = try jobsRoot ?? DerrickFilePaths.fileJobsRoot()
        let exports = try exportsRoot ?? DerrickFilePaths.fileExportsRoot()
        let jobRoot = jobs.appendingPathComponent(jobID, isDirectory: true)
        let inputDirectory = jobRoot.appendingPathComponent("in", isDirectory: true)
        let outputDirectory = jobRoot.appendingPathComponent("out", isDirectory: true)
        let exportDirectory = exports.appendingPathComponent(jobID, isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o777], ofItemAtPath: outputDirectory.path)

        var usedNames: Set<String> = []
        var copied: [String] = []
        for item in selected {
            let unique = uniqued(DerrickFilePaths.sanitizedPathComponent(item.name), used: &usedNames)
            try fileManager.copyItem(
                at: item.url,
                to: inputDirectory.appendingPathComponent(unique)
            )
            copied.append(unique)
        }
        return FileJobWorkspace(
            jobID: jobID,
            inputDirectory: inputDirectory,
            outputDirectory: outputDirectory,
            exportDirectory: exportDirectory,
            copiedFilenames: copied
        )
    }

    public func publishOutputs() throws -> [String] {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var names: [String] = []
        for url in contents where url.hasDirectoryPath == false {
            let destination = exportDirectory.appendingPathComponent(url.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: url, to: destination)
            names.append(url.lastPathComponent)
        }
        return names.sorted()
    }

    public func removeJobDirectories() {
        try? FileManager.default.removeItem(at: inputDirectory.deletingLastPathComponent())
    }

    private static func discoverFiles(in sessionDirectory: URL) throws -> [(name: String, url: URL)] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionDirectory.path) else {
            return []
        }
        let enumerator = fileManager.enumerator(
            at: sessionDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var files: [(name: String, url: URL)] = []
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            files.append((url.lastPathComponent, url))
        }
        return files.sorted { $0.name < $1.name }
    }

    private static func uniqued(_ name: String, used: inout Set<String>) -> String {
        if used.insert(name.lowercased()).inserted {
            return name
        }
        let url = URL(fileURLWithPath: name)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            if used.insert(candidate.lowercased()).inserted {
                return candidate
            }
            index += 1
        }
    }
}

public enum FileJobWorkspaceError: Error, LocalizedError, Sendable, Equatable {
    case missingSession
    case noAttachments
    case missingFile(String)
    case unsafeFilename(String)
    case tooManyFiles

    public var errorDescription: String? {
        switch self {
        case .missingSession:
            return "Open a chat before extracting files."
        case .noAttachments:
            return "This chat has no attached files."
        case .missingFile(let name):
            return "\(name) is not attached to this chat."
        case .unsafeFilename(let name):
            return "\(name) is not a safe file name."
        case .tooManyFiles:
            return "You can process at most 5 files."
        }
    }
}
