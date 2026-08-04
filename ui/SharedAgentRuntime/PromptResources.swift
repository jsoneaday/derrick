import Foundation

public enum PromptResources {
    public static func conversationRAGInstructions(
        from resourceRoot: URL = Bundle.main.resourceURL ?? Bundle.main.bundleURL,
        prefixTxt: String? = nil
    ) throws -> String {
        try load(named: "conversation_rag_instructions", from: resourceRoot, prefixTxt)
    }

    public static func memorySummarizerInstructions(from resourceRoot: URL = Bundle.main.resourceURL ?? Bundle.main.bundleURL) throws -> String {
        try load(named: "memory_summarizer_instructions", from: resourceRoot)
    }

    public static func mcpToolInstructions(from resourceRoot: URL = Bundle.main.resourceURL ?? Bundle.main.bundleURL) throws -> String {
        try load(named: "mcp_tool_instructions", from: resourceRoot)
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
