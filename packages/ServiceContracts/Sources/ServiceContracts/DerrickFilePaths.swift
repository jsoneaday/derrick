import Foundation

/// Shared attachment and file-job paths (UI + MCPService).
public enum DerrickFilePaths {
    public static let attachmentsDirectoryName = "chat-attachments"
    public static let fileJobsDirectoryName = "file-jobs"
    public static let fileExportsDirectoryName = "file-exports"

    public static func attachmentsRoot(
        applicationName: String = DerrickAppSupport.defaultApplicationName
    ) throws -> URL {
        try DerrickAppSupport.databaseDirectory(applicationName: applicationName)
            .appendingPathComponent(attachmentsDirectoryName, isDirectory: true)
    }

    public static func fileJobsRoot(
        applicationName: String = DerrickAppSupport.defaultApplicationName
    ) throws -> URL {
        try DerrickAppSupport.databaseDirectory(applicationName: applicationName)
            .appendingPathComponent(fileJobsDirectoryName, isDirectory: true)
    }

    public static func fileExportsRoot(
        applicationName: String = DerrickAppSupport.defaultApplicationName
    ) throws -> URL {
        try DerrickAppSupport.databaseDirectory(applicationName: applicationName)
            .appendingPathComponent(fileExportsDirectoryName, isDirectory: true)
    }

    public static func sanitizedPathComponent(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "file" }
        var scalars: [Character] = []
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        for scalar in trimmed.unicodeScalars {
            if scalar == "/" || scalar == ":" || scalar == "\\" {
                scalars.append("_")
            } else if allowed.contains(scalar) {
                scalars.append(Character(scalar))
            } else {
                scalars.append("_")
            }
        }
        var result = String(scalars)
        while result.contains("..") {
            result = result.replacingOccurrences(of: "..", with: "_")
        }
        if result.isEmpty || result == "." {
            return "file"
        }
        return String(result.prefix(200))
    }
}
