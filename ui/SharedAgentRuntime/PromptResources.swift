import Foundation

public enum PromptResources {
    /// Bundle resources for prompt `.md` files. LoginItem (`derrickd`) walks up to host `Derrick.app`.
    public static func resolvedResourceRoot() -> URL {
        let main = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        if containsPrompts(in: main) {
            return main
        }
        for candidate in hostAppResourceRoots() {
            if containsPrompts(in: candidate) {
                return candidate
            }
        }
        return main
    }

    public static func conversationRAGInstructions(
        from resourceRoot: URL? = nil,
        prefixTxt: String? = nil
    ) throws -> String {
        try load(named: "conversation_rag_instructions", from: resourceRoot ?? resolvedResourceRoot(), prefixTxt)
    }

    public static func memorySummarizerInstructions(from resourceRoot: URL? = nil) throws -> String {
        try load(named: "memory_summarizer_instructions", from: resourceRoot ?? resolvedResourceRoot())
    }

    public static func mcpToolInstructions(from resourceRoot: URL? = nil) throws -> String {
        try load(named: "mcp_tool_instructions", from: resourceRoot ?? resolvedResourceRoot())
    }

    public static func softwareFactoryInstructions(from resourceRoot: URL? = nil) throws -> String {
        try load(named: "software_factory_instructions", from: resourceRoot ?? resolvedResourceRoot())
    }

    private static func containsPrompts(in resourceRoot: URL) -> Bool {
        let probe = resourceRoot.appendingPathComponent("conversation_rag_instructions.md")
        if FileManager.default.fileExists(atPath: probe.path) { return true }
        let nested = resourceRoot
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("conversation_rag_instructions.md")
        return FileManager.default.fileExists(atPath: nested.path)
    }

    /// Walk ancestor `.app` bundles (LoginItems/JobKeepAlive → Derrick.app Resources).
    private static func hostAppResourceRoots() -> [URL] {
        var urls: [URL] = []
        var dir = Bundle.main.bundleURL.standardizedFileURL
        for _ in 0..<12 {
            if dir.pathExtension == "app" {
                urls.append(dir.appendingPathComponent("Contents/Resources", isDirectory: true))
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return urls
    }

    private static func load(named name: String, from resourceRoot: URL, _ prefixTxt: String? = nil) throws -> String {
        let candidates = [
            resourceRoot.appendingPathComponent("\(name).md"),
            resourceRoot.appendingPathComponent("Resources", isDirectory: true).appendingPathComponent("\(name).md")
        ]

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            let contents = try String(contentsOf: url, encoding: .utf8)
            
            let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            return prefixTxt.map { "\($0)\n\n\(trimmed)" } ?? trimmed
        }

        throw PromptResourcesError.missingResource(name: name, resourceRoot: resourceRoot)
    }

    public static func currentDatePrefix(date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "MMMM d yyyy h:mma"
        let timestamp = formatter.string(from: date).replacingOccurrences(of: "AM", with: "am").replacingOccurrences(of: "PM", with: "pm")
        return "Today's date is \(timestamp)"
    }
}

public enum PromptResourcesError: Error, Equatable, LocalizedError {
    case missingResource(name: String, resourceRoot: URL)

    public var errorDescription: String? {
        switch self {
        case .missingResource(let name, let resourceRoot):
            return "Missing prompt resource \(name).md in \(resourceRoot.path)."
        }
    }
}
