import Foundation

/// Progressive disclosure for Agent Plugin skills and host UI catalog.
/// Index always; full bodies and references only when activated or requested.
public enum PluginSkillDisclosure: Sendable {
    public struct IndexEntry: Sendable, Hashable, Identifiable {
        public var id: String { "\(pluginID)/\(skillName)" }
        public let pluginID: String
        public let skillName: String
        public let description: String
        public let skillMarkdownPath: String

        public init(
            pluginID: String,
            skillName: String,
            description: String,
            skillMarkdownPath: String
        ) {
            self.pluginID = pluginID
            self.skillName = skillName
            self.description = description
            self.skillMarkdownPath = skillMarkdownPath
        }
    }

    /// Cheap routing index: skill name + description only.
    public static func index(from release: PluginFactoryRelease) -> [IndexEntry] {
        release.skillFiles.keys
            .filter { PluginFactorySkillFile.isSkillMarkdownPath($0) }
            .sorted()
            .map { path in
                let body = release.skillFiles[path] ?? ""
                let front = SkillFrontmatter.parse(body)
                let directory = path.split(separator: "/")[1]
                let name = front.name ?? String(directory)
                return IndexEntry(
                    pluginID: release.pluginID,
                    skillName: name,
                    description: front.description ?? release.reviewSummary,
                    skillMarkdownPath: path
                )
            }
    }

    public static func index(from releases: [PluginFactoryRelease]) -> [IndexEntry] {
        releases.flatMap { index(from: $0) }
            .sorted { lhs, rhs in
                if lhs.pluginID != rhs.pluginID { return lhs.pluginID < rhs.pluginID }
                return lhs.skillName < rhs.skillName
            }
    }

    /// Full SKILL.md body when the skill is activated.
    public static func activate(
        skillFiles: [String: String],
        skillNameOrPath: String
    ) -> String? {
        if let direct = skillFiles[skillNameOrPath],
           PluginFactorySkillFile.isSkillMarkdownPath(skillNameOrPath) {
            return direct
        }
        let needle = skillNameOrPath.trimmingCharacters(in: .whitespacesAndNewlines)
        for (path, body) in skillFiles where PluginFactorySkillFile.isSkillMarkdownPath(path) {
            let directory = String(path.split(separator: "/")[1])
            let front = SkillFrontmatter.parse(body)
            if directory == needle || front.name == needle || path == needle {
                return body
            }
        }
        return nil
    }

    /// On-demand: return a reference file when the model asks for it by path or filename.
    public static func reference(
        skillFiles: [String: String],
        requested: String
    ) -> (path: String, body: String)? {
        let needle = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        if let body = skillFiles[needle], PluginFactorySkillFile.isSkillReferencePath(needle) {
            return (needle, body)
        }
        let filename = (needle as NSString).lastPathComponent
        for (path, body) in skillFiles where PluginFactorySkillFile.isSkillReferencePath(path) {
            if path == needle
                || path.hasSuffix("/\(needle)")
                || (path as NSString).lastPathComponent == filename {
                return (path, body)
            }
        }
        return nil
    }

    public static func referencePaths(skillFiles: [String: String]) -> [String] {
        skillFiles.keys.filter { PluginFactorySkillFile.isSkillReferencePath($0) }.sorted()
    }

    /// System-prompt block: routing index only (no SKILL bodies).
    public static func indexPromptBlock(entries: [IndexEntry]) -> String {
        guard !entries.isEmpty else { return "" }
        var lines = [
            "Installed Agent Plugin skills (routing index only).",
            "Call plugin.skill with action=activate and the skill name for full SKILL.md.",
            "Call plugin.skill with action=reference and a references path when the skill says to open one:",
        ]
        for entry in entries {
            lines.append("- /\(entry.pluginID) · \(entry.skillName): \(entry.description)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Progressive disclosure for the host UI control library.
public enum HostUIDisclosure: Sendable {
    /// Element id + one-line purpose for builder prompts (not full schemas).
    public static func catalogSummary() throws -> String {
        let json = try HostUILibraryStore.loadJSON()
        guard let elements = json["elements"] as? [String: Any] else {
            throw HostUILibraryError.invalidJSON
        }
        var lines: [String] = [
            "Host UI catalog (ids only). Ask for an element schema before using unfamiliar config keys.",
            "Emit ui.present trees using only these element ids. The Swift host renders controls and runs host services.",
            "Prefer the messaging_inbox example as the default present tree; adapt from it. The host never substitutes a screen. Do not reimplement send, poll, banners, or reply chrome in guest code.",
            "Elements with role=service are invisible host capabilities (optimistic_send, inbound_banners, poll_refresh, reply_pane). They run only when the present tree includes them.",
        ]
        let controls = elements.keys.sorted().filter { id in
            (elements[id] as? [String: Any])?["role"] as? String != "service"
        }
        let services = elements.keys.sorted().filter { id in
            (elements[id] as? [String: Any])?["role"] as? String == "service"
        }
        lines.append("Controls:")
        for id in controls {
            lines.append("- \(id): \(elementDescription(id, in: elements))")
        }
        if !services.isEmpty {
            lines.append("Services (host-owned, invisible):")
            for id in services {
                lines.append("- \(id): \(elementDescription(id, in: elements))")
            }
        }
        if let examples = json["examples"] as? [String: Any] {
            lines.append("Named examples (ask by name for full tree): \(examples.keys.sorted().joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private static func elementDescription(_ id: String, in elements: [String: Any]) -> String {
        if let obj = elements[id] as? [String: Any],
           let text = obj["description"] as? String {
            return text
        }
        return "Host control."
    }

    /// Full element definition when the model asks for a specific control.
    public static func elementSchema(id: String) throws -> String {
        let json = try HostUILibraryStore.loadJSON()
        guard let elements = json["elements"] as? [String: Any],
              let element = elements[id] else {
            throw HostUILibraryError.unknownElement(id)
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["element": id, "schema": element],
            options: [.prettyPrinted, .sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    /// Full example tree when the model asks for a named example (e.g. messaging_inbox).
    public static func exampleTree(named name: String) throws -> String {
        let node = try HostUILibraryStore.example(named: name)
        let data = try JSONEncoder().encode(node)
        let object = try JSONSerialization.jsonObject(with: data)
        let pretty = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        return String(decoding: pretty, as: UTF8.self)
    }
}
