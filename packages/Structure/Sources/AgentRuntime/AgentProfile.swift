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

/// Parses `$handle` anywhere in a message (token boundary), not only at the start.
public enum AgentProfileTokenParser {
    public static func parse(message: String) -> (handle: String?, body: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tokenRange = AgentProfileTokenHighlight.ranges(in: trimmed).first(where: {
            trimmed[$0].hasPrefix("$")
        }) else {
            return (nil, trimmed)
        }
        let token = String(trimmed[tokenRange])
        let handle = AgentProfileHandle.normalize(String(token.dropFirst()))
        var body = trimmed
        body.removeSubrange(tokenRange)
        let collapsed = body
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (handle, collapsed)
    }
}

/// Ranges of `$handle` tokens (and the profile name inside `[Derrick:handle]`) for UI highlighting.
public enum AgentProfileTokenHighlight {
    public static func ranges(
        in text: String,
        productName: String = DerrickAppSupport.hostAppProductName
    ) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        found.append(contentsOf: dollarHandleRanges(in: text))
        found.append(contentsOf: productPrefixedHandleRanges(in: text, productName: productName))
        return found.sorted { $0.lowerBound < $1.lowerBound }
    }

    public static func nsRanges(
        in text: String,
        productName: String = DerrickAppSupport.hostAppProductName
    ) -> [NSRange] {
        ranges(in: text, productName: productName).map { NSRange($0, in: text) }
    }

    private static func dollarHandleRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "$", isTokenBoundary(before: index, in: text) {
                let handleStart = text.index(after: index)
                var handleEnd = handleStart
                while handleEnd < text.endIndex, isHandleCharacter(text[handleEnd]) {
                    handleEnd = text.index(after: handleEnd)
                }
                let handle = String(text[handleStart..<handleEnd])
                if isHighlightableHandle(handle) {
                    ranges.append(index..<handleEnd)
                    index = handleEnd
                    continue
                }
            }
            index = text.index(after: index)
        }
        return ranges
    }

    private static func productPrefixedHandleRanges(
        in text: String,
        productName: String
    ) -> [Range<String.Index>] {
        let needle = "[\(productName):"
        var ranges: [Range<String.Index>] = []
        var searchFrom = text.startIndex
        while searchFrom < text.endIndex,
              let prefix = text.range(of: needle, range: searchFrom..<text.endIndex) {
            let handleStart = prefix.upperBound
            guard let close = text[handleStart...].firstIndex(of: "]") else { break }
            let handle = String(text[handleStart..<close])
            if isHighlightableHandle(handle) {
                ranges.append(handleStart..<close)
            }
            searchFrom = close
            if searchFrom < text.endIndex {
                searchFrom = text.index(after: searchFrom)
            }
        }
        return ranges
    }

    private static func isHighlightableHandle(_ handle: String) -> Bool {
        AgentProfileHandle.isValid(handle) && handle.contains(where: \.isLetter)
    }

    private static func isTokenBoundary(before index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else { return true }
        let previous = text[text.index(before: index)]
        return !previous.isLetter && !previous.isNumber && previous != "_"
    }

    private static func isHandleCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }
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
