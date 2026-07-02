import Foundation

enum PromptResources {
    static func conversationRAGInstructions(from resourceRoot: URL = Bundle.main.resourceURL ?? Bundle.main.bundleURL) throws -> String {
        try load(named: "conversation_rag_instructions", from: resourceRoot)
    }

    static func memorySummarizerInstructions(from resourceRoot: URL = Bundle.main.resourceURL ?? Bundle.main.bundleURL) throws -> String {
        try load(named: "memory_summarizer_instructions", from: resourceRoot)
    }

    private static func load(named name: String, from resourceRoot: URL) throws -> String {
        let candidates = [
            resourceRoot.appendingPathComponent("\(name).md"),
            resourceRoot.appendingPathComponent("Resources", isDirectory: true).appendingPathComponent("\(name).md")
        ]

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            let contents = try String(contentsOf: url, encoding: .utf8)
            return contents.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        throw PromptResourcesError.missingResource(name: name, resourceRoot: resourceRoot)
    }
}

enum PromptResourcesError: Error, Equatable, LocalizedError {
    case missingResource(name: String, resourceRoot: URL)

    var errorDescription: String? {
        switch self {
        case .missingResource(let name, let resourceRoot):
            return "Missing prompt resource \(name).md in \(resourceRoot.path)."
        }
    }
}
