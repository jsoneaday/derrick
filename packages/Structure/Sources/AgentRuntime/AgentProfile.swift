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

    public static let allBuiltins = [orchestrator, developer]

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

    public static func orchestratorDefault(modelJSON: Data) -> AgentProfile {
        AgentProfile(
            id: "builtin-orchestrator",
            displayName: "Orchestrator",
            handle: AgentProfileHandle.orchestrator,
            instructions: """
            You are Derrick's orchestrator — the default generalist profile.

            Your job is to understand what the user wants, break work into clear steps, and \
            coordinate execution. For implementation, debugging, code review, or technical changes, \
            prefer delegating to the Developer profile ($developer). Summarize outcomes for the \
            user in plain language and report blockers early.

            Stay concise unless the user asks for detail.
            """,
            modelJSON: modelJSON,
            rag: .default,
            isEnabled: true,
            isBuiltin: true,
            sortOrder: 0
        )
    }

    public static func developerDefault(modelJSON: Data) -> AgentProfile {
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
            rag: .default,
            isEnabled: true,
            isBuiltin: true,
            sortOrder: 1
        )
    }

    public static func builtinProfiles(modelJSON: Data) -> [AgentProfile] {
        [
            orchestratorDefault(modelJSON: modelJSON),
            developerDefault(modelJSON: modelJSON),
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
