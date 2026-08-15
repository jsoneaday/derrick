import Foundation

/// Plugin-relative paths (`./foo/bar`) and root-containment checks.
public enum PluginPath {
    /// Requires `./…`, no empty segments, no `.` / `..` segments.
    public static func validateRelative(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("./") else {
            throw PluginManifestError.pathNotRelative(raw)
        }
        let rest = String(trimmed.dropFirst(2))
        guard !rest.isEmpty else {
            throw PluginManifestError.pathNotRelative(raw)
        }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw PluginManifestError.pathEscapesRoot(raw)
        }
        return trimmed
    }

    public static func validateJSEntrypoint(_ raw: String) throws -> String {
        let path = try validateRelative(raw)
        guard path.hasSuffix(".js") || path.hasSuffix(".ts") else {
            throw PluginManifestError.invalidEntrypoint(raw)
        }
        return path
    }

    public static func resolve(root: URL, relative: String) throws -> URL {
        let relative = try validateRelative(relative)
        let rootResolved = root.resolvingSymlinksInPath().standardizedFileURL
        let candidate = rootResolved
            .appendingPathComponent(String(relative.dropFirst(2)))
            .resolvingSymlinksInPath()
            .standardizedFileURL
        try ensureContained(resolved: candidate, rootPath: rootResolved.path)
        return candidate
    }

    public static func ensureContained(resolved: URL, rootPath: String) throws {
        let path = resolved.path
        if path == rootPath { return }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else {
            throw PluginManifestError.pathEscapesRoot(path)
        }
    }

    public static func posixRelative(of resolved: URL, rootPath: String) -> String {
        let path = resolved.path
        if path == rootPath { return "" }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return String(path.dropFirst(prefix.count))
    }
}
