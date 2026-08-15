import CryptoKit
import Foundation

/// SHA-256 of the hashed plugin tree (`plugin.json`, `app.derrick/**`,
/// `skills/**`, `bun.lock`). `node_modules` is excluded.
public struct PluginContentHash: RawRepresentable, Codable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String

    public var description: String { rawValue }

    public var prefix8: String { String(rawValue.prefix(8)) }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(hex: String) throws {
        let hex = hex.lowercased()
        guard hex.count == 64, hex.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
            throw PluginManifestError.invalidContentHash(hex)
        }
        rawValue = hex
    }

    public static func hash(files: [String: Data]) -> PluginContentHash {
        var hasher = SHA256()
        for path in files.keys.sorted() {
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: files[path] ?? Data())
            hasher.update(data: Data([0]))
        }
        let digest = hasher.finalize()
        return PluginContentHash(rawValue: digest.map { String(format: "%02x", $0) }.joined())
    }

    public static func hash(root: URL) throws -> PluginContentHash {
        try hash(files: collectHashableFiles(root: root))
    }

    public static func collectHashableFiles(root: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        let fm = FileManager.default
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path

        func consider(_ url: URL) throws {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            try PluginPath.ensureContained(resolved: resolved, rootPath: rootPath)
            let relative = PluginPath.posixRelative(of: resolved, rootPath: rootPath)
            guard PluginContentHash.shouldHash(relativePath: relative) else { return }
            files[relative] = try Data(contentsOf: resolved)
        }

        try consider(root.appendingPathComponent("plugin.json"))
        try consider(root.appendingPathComponent("bun.lock"))
        for folder in ["app.derrick", "skills"] {
            let dir = root.appendingPathComponent(folder)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let enumerator = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let fileURL as URL in enumerator {
                if fileURL.path.contains("/node_modules/") || fileURL.lastPathComponent == "node_modules" {
                    enumerator.skipDescendants()
                    continue
                }
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                if values.isRegularFile == true {
                    try consider(fileURL)
                }
            }
        }
        return files
    }

    public static func shouldHash(relativePath: String) -> Bool {
        if relativePath == "plugin.json" || relativePath == "bun.lock" { return true }
        if relativePath.hasPrefix("app.derrick/") { return !relativePath.contains("/node_modules/") }
        if relativePath.hasPrefix("skills/") { return true }
        return false
    }
}
