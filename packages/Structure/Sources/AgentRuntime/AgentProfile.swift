import Foundation

public struct AgentProfileRAGConfig: Codable, Sendable, Hashable {
    public var useDefaultInstructions: Bool
    public var customInstructions: String?
    public var retrievalLimit: Int
    public var useSessionMemory: Bool

    public init(
        useDefaultInstructions: Bool = true,
        customInstructions: String? = nil,
        retrievalLimit: Int = 5,
        useSessionMemory: Bool = true
    ) {
        self.useDefaultInstructions = useDefaultInstructions
        self.customInstructions = customInstructions
        self.retrievalLimit = min(max(retrievalLimit, 0), 20)
        self.useSessionMemory = useSessionMemory
    }

    public static let `default` = AgentProfileRAGConfig()
}

public enum AgentProfileHandle {
    public static let orchestrator = "orchestrator"

    public static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isValid(trimmed) else { return nil }
        return trimmed
    }

    public static func isValid(_ handle: String) -> Bool {
        guard !handle.isEmpty, handle.count <= 48 else { return false }
        return handle.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }
    }
}

/// Parses `$handle` at the start of a message body (after optional bot mention stripping).
public enum AgentProfileTokenParser {
    public static func parse(message: String) -> (handle: String?, body: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("$") else {
            return (nil, trimmed)
        }
        let remainder = String(trimmed.dropFirst())
        guard let end = remainder.firstIndex(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) else {
            let handle = AgentProfileHandle.normalize(remainder)
            return (handle, "")
        }
        let token = String(remainder[..<end])
        let handle = AgentProfileHandle.normalize(token)
        let body = String(remainder[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (handle, body)
    }
}

public struct AgentProfile: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public var displayName: String
    public var handle: String
    public var instructions: String
    public var modelJSON: Data
    public var thinkingJSON: Data?
    public var rag: AgentProfileRAGConfig
    public var isEnabled: Bool
    public var isBuiltin: Bool
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        displayName: String,
        handle: String,
        instructions: String,
        modelJSON: Data,
        thinkingJSON: Data? = nil,
        rag: AgentProfileRAGConfig = .default,
        isEnabled: Bool = true,
        isBuiltin: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.displayName = displayName
        self.handle = handle
        self.instructions = instructions
        self.modelJSON = modelJSON
        self.thinkingJSON = thinkingJSON
        self.rag = rag
        self.isEnabled = isEnabled
        self.isBuiltin = isBuiltin
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func resolvedRAGInstructions(defaultInstructions: String) -> String {
        if rag.useDefaultInstructions {
            return defaultInstructions
        }
        let custom = rag.customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? defaultInstructions : custom
    }

    public var resolvedRetrievalLimit: Int {
        rag.useSessionMemory ? rag.retrievalLimit : 0
    }

    public static func orchestratorDefault(modelJSON: Data) -> AgentProfile {
        AgentProfile(
            id: "builtin-orchestrator",
            displayName: "Orchestrator",
            handle: AgentProfileHandle.orchestrator,
            instructions: """
            You are Derrick's default orchestrator profile. Coordinate work, stay focused on the user's \
            request, and produce clear actionable replies. Prefer concise answers unless detail is needed.
            """,
            modelJSON: modelJSON,
            rag: .default,
            isEnabled: true,
            isBuiltin: true,
            sortOrder: 0
        )
    }
}

public struct AgentProfileTurnContext: Codable, Sendable, Hashable {
    public let handle: String
    public let displayName: String
    public let instructions: String
    public let modelJSON: Data
    public let thinkingJSON: Data?
    public let rag: AgentProfileRAGConfig

    public init(profile: AgentProfile) {
        handle = profile.handle
        displayName = profile.displayName
        instructions = profile.instructions
        modelJSON = profile.modelJSON
        thinkingJSON = profile.thinkingJSON
        rag = profile.rag
    }
}
