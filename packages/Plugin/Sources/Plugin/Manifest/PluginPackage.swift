import Foundation

/// Loaded Agent Plugin directory. Skills-only packs have `runtime == nil`.
public struct PluginPackage: Sendable, Hashable {
    public var manifest: AgentPluginManifest
    public var runtime: DerrickRuntime?
    public var skills: [DiscoveredSkill]
    public var contentHash: PluginContentHash
    public var skippedSkills: [String]

    public var pluginID: PluginID { manifest.name }
    public var isHandlePlugin: Bool { runtime != nil }

    public static func load(from root: URL) throws -> PluginPackage {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let manifestURL = root.appendingPathComponent("plugin.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw PluginManifestError.missingFile("plugin.json")
        }
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try AgentPluginManifest.decode(manifestData)

        var runtime: DerrickRuntime?
        if let pointers = manifest.derrick, pointers.runtime != nil || pointers.entrypoint != nil {
            runtime = try loadRuntime(root: root, pointers: pointers)
        }

        let (skills, skipped) = discoverSkills(root: root)
        let contentHash = try PluginContentHash.hash(root: root)
        return PluginPackage(
            manifest: manifest,
            runtime: runtime,
            skills: skills,
            contentHash: contentHash,
            skippedSkills: skipped
        )
    }

    private static func loadRuntime(root: URL, pointers: DerrickExtensionPointers) throws -> DerrickRuntime {
        let runtimeRel = pointers.runtime ?? "./\(PluginContract.derrickExtensionNamespace)/runtime.json"
        let runtimeURL = try PluginPath.resolve(root: root, relative: runtimeRel)
        guard FileManager.default.fileExists(atPath: runtimeURL.path) else {
            throw PluginManifestError.missingRuntime
        }
        let data = try Data(contentsOf: runtimeURL)
        var runtime = try PluginDecoding.decode(DerrickRuntime.self, from: data)
        if let entry = pointers.entrypoint {
            runtime.entrypoint = try PluginPath.validateJSEntrypoint(entry)
        }

        let entryURL = try PluginPath.resolve(root: root, relative: runtime.entrypoint)
        guard FileManager.default.fileExists(atPath: entryURL.path) else {
            throw PluginManifestError.missingFile(runtime.entrypoint)
        }

        if runtime.requiresLockfile {
            let lockCandidates = [
                "./\(PluginContract.derrickExtensionNamespace)/bun.lock",
                "./bun.lock",
            ]
            let found = lockCandidates.contains { rel in
                (try? PluginPath.resolve(root: root, relative: rel)).map {
                    FileManager.default.fileExists(atPath: $0.path)
                } ?? false
            }
            if !found {
                throw PluginManifestError.missingLockfile
            }
        }
        return runtime
    }

    /// Immediate `skills/*/SKILL.md` only. Invalid skills are skipped.
    public static func discoverSkills(root: URL) -> (skills: [DiscoveredSkill], skipped: [String]) {
        let skillsDir = root.appendingPathComponent("skills")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: skillsDir.path, isDirectory: &isDir), isDir.boolValue else {
            return ([], [])
        }
        var skills: [DiscoveredSkill] = []
        var skipped: [String] = []
        let children = (try? FileManager.default.contentsOfDirectory(
            at: skillsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var childDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: child.path, isDirectory: &childDir), childDir.boolValue else {
                continue
            }
            let skillFile = child.appendingPathComponent("SKILL.md")
            var regular: ObjCBool = false
            guard FileManager.default.fileExists(atPath: skillFile.path, isDirectory: &regular), !regular.boolValue else {
                skipped.append(child.lastPathComponent)
                continue
            }
            do {
                let text = try String(contentsOf: skillFile, encoding: .utf8)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    skipped.append(child.lastPathComponent)
                    continue
                }
                let front = SkillFrontmatter.parse(text)
                let name = front.name ?? child.lastPathComponent
                skills.append(
                    DiscoveredSkill(
                        directoryName: child.lastPathComponent,
                        name: name,
                        description: front.description,
                        relativePath: "./skills/\(child.lastPathComponent)/SKILL.md"
                    )
                )
            } catch {
                skipped.append(child.lastPathComponent)
            }
        }
        return (skills, skipped)
    }
}

public struct DiscoveredSkill: Sendable, Hashable {
    public var directoryName: String
    public var name: String
    public var description: String?
    public var relativePath: String

    public init(directoryName: String, name: String, description: String? = nil, relativePath: String) {
        self.directoryName = directoryName
        self.name = name
        self.description = description
        self.relativePath = relativePath
    }
}

enum SkillFrontmatter {
    static func parse(_ text: String) -> (name: String?, description: String?) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return (nil, nil) }
        let rest = normalized.dropFirst(4)
        guard let end = rest.range(of: "\n---") else { return (nil, nil) }
        let block = String(rest[..<end.lowerBound])
        var name: String?
        var description: String?
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            if let value = yamlScalar(line, key: "name") { name = value }
            if let value = yamlScalar(line, key: "description") { description = value }
        }
        return (name, description)
    }

    private static func yamlScalar(_ line: String, key: String) -> String? {
        let prefix = "\(key):"
        guard line.hasPrefix(prefix) else { return nil }
        var value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }
}
