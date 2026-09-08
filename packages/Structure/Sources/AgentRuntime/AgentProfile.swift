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
    public static let developer = "developer"
    public static let researcher = "researcher"
    public static let general = "general"

    public static let allBuiltins = [orchestrator, developer, researcher, general]

    /// Profiles the orchestrator may delegate to via `agent_profile_delegate`.
    public static let delegateTargets = [developer, researcher, general]

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

    public static func orchestratorDefault(modelJSON: Data, thinkingJSON: Data? = nil) -> AgentProfile {
        AgentProfile(
            id: "builtin-orchestrator",
            displayName: "Orchestrator",
            handle: AgentProfileHandle.orchestrator,
            instructions: """
            You are Derrick's orchestrator — a router-first generalist.

            Understand what the user wants. You may research or clarify yourself before routing. \
            Handle simple requests directly when delegation is unnecessary.

            When another profile fits better, delegate with `agent_profile_delegate`:
            - `developer` — code, debugging, implementation, technical execution
            - `researcher` — research, summarization, synthesis from sources
            - `general` — everyday workhorse tasks when no specialist fits

            Use `general` when unsure which specialist fits. Summarize delegated outcomes in plain \
            language and report blockers early.

            Stay concise unless the user asks for detail.
            """,
            modelJSON: modelJSON,
            thinkingJSON: thinkingJSON,
            rag: .default,
            isEnabled: true,
            isBuiltin: true,
            sortOrder: 0
        )
    }

    public static func developerDefault(modelJSON: Data, thinkingJSON: Data? = nil) -> AgentProfile {
        AgentProfile(
            id: "builtin-developer",
            displayName: "Developer",
            handle: AgentProfileHandle.developer,
            instructions: """
            You are Derrick's Developer profile. Focus on code, debugging, implementation plans, \
            and concrete technical execution. Prefer actionable steps, precise file or API references \
            when known, and working solutions over theory.

            When scope is unclear, ask one focused clarifying question before diving in.
            """,
            modelJSON: modelJSON,
            thinkingJSON: thinkingJSON,
            rag: .default,
            isEnabled: true,
            isBuiltin: true,
            sortOrder: 1
        )
    }

    public static func researcherDefault(modelJSON: Data, thinkingJSON: Data? = nil) -> AgentProfile {
        AgentProfile(
            id: "builtin-researcher",
            displayName: "Researcher",
            handle: AgentProfileHandle.researcher,
            instructions: """
            You are Derrick's Researcher profile. Find, read, and synthesize information. Summarize \
            clearly with sources when available. Prefer accurate synthesis over speculation.

            When research is incomplete, say what is known, what is uncertain, and what would help next.
            """,
            modelJSON: modelJSON,
            thinkingJSON: thinkingJSON,
            rag: .default,
            isEnabled: true,
            isBuiltin: true,
            sortOrder: 2
        )
    }

    public static func generalDefault(modelJSON: Data, thinkingJSON: Data? = nil) -> AgentProfile {
        AgentProfile(
            id: "builtin-general",
            displayName: "General",
            handle: AgentProfileHandle.general,
            instructions: """
            You are Derrick's General profile — the workhorse for everyday tasks: writing, planning, \
            brainstorming, mixed requests, and anything that does not need a specialist. Be practical, \
            direct, and helpful.

            When scope is unclear, ask one focused clarifying question before proceeding.
            """,
            modelJSON: modelJSON,
            thinkingJSON: thinkingJSON,
            rag: .default,
            isEnabled: true,
            isBuiltin: true,
            sortOrder: 3
        )
    }

    public static func builtinProfiles(modelJSON: Data, thinkingJSON: Data? = nil) -> [AgentProfile] {
        [
            orchestratorDefault(modelJSON: modelJSON, thinkingJSON: thinkingJSON),
            developerDefault(modelJSON: modelJSON, thinkingJSON: thinkingJSON),
            researcherDefault(modelJSON: modelJSON, thinkingJSON: thinkingJSON),
            generalDefault(modelJSON: modelJSON, thinkingJSON: thinkingJSON),
        ]
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
