import Foundation
import ServiceContracts

public enum PromptResources {
    /// Bundle resources for prompt `.md` files. LoginItem (`derrickd`) walks up to host `Derrick.app`.
    public static func resolvedResourceRoot() -> URL {
        DerrickBundledText.resolvedResourceRoot()
            ?? Bundle.main.resourceURL
            ?? Bundle.main.bundleURL
    }

    public static func conversationRAGInstructions(
        from resourceRoot: URL? = nil,
        prefixTxt: String? = nil
    ) throws -> String {
        try load(named: "conversation_rag_instructions", from: resourceRoot, prefixTxt: prefixTxt)
    }

    public static func memorySummarizerInstructions(from resourceRoot: URL? = nil) throws -> String {
        try load(named: "memory_summarizer_instructions", from: resourceRoot)
    }

    public static func mcpToolInstructions(from resourceRoot: URL? = nil) throws -> String {
        try load(named: "mcp_tool_instructions", from: resourceRoot)
    }

    public static func softwareFactoryInstructions(from resourceRoot: URL? = nil) throws -> String {
        try load(named: "software_factory_instructions", from: resourceRoot)
    }

    public static func pluginHandleInstructions(from resourceRoot: URL? = nil) throws -> String {
        try DerrickBundledText.load("plugin_handle_instructions.md", from: resourceRoot)
    }

    public static func scriptReviewerInstructions(from resourceRoot: URL? = nil) throws -> String {
        try DerrickBundledText.load("script_reviewer_instructions.md", from: resourceRoot)
    }

    public static func factoryReviewerInstructions(from resourceRoot: URL? = nil) throws -> String {
        try DerrickBundledText.load("factory_reviewer_instructions.md", from: resourceRoot)
    }

    public static func workerOverlay(from resourceRoot: URL? = nil) throws -> String {
        try DerrickBundledText.load("worker_overlay.md", from: resourceRoot)
    }

    public static func userFacingSpawnOverlay(from resourceRoot: URL? = nil) throws -> String {
        try DerrickBundledText.load("user_facing_spawn_overlay.md", from: resourceRoot)
    }

    /// Full guest SDK (`derrick.ts`) wrapped for a model prompt.
    public static func guestSDKForModel(from resourceRoot: URL? = nil) throws -> String {
        let source = try DerrickBundledText.load("guest/derrick.ts", from: resourceRoot)
        return DerrickBundledText.formatTypeScriptForModel(
            source,
            heading: "derrick module (`import { … } from \"derrick\"`)"
        )
    }

    public static func guestSDKSource(from resourceRoot: URL? = nil) throws -> String {
        try DerrickBundledText.load("guest/derrick.ts", from: resourceRoot)
    }

    private static func load(named name: String, from resourceRoot: URL?, prefixTxt: String? = nil) throws -> String {
        let root = resourceRoot ?? resolvedResourceRoot()
        do {
            let contents = try DerrickBundledText.load("\(name).md", from: resourceRoot)
            return prefixTxt.map { "\($0)\n\n\(contents)" } ?? contents
        } catch {
            throw PromptResourcesError.missingResource(name: name, resourceRoot: root)
        }
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
