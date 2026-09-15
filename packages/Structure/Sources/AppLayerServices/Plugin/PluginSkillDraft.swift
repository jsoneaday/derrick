import Foundation

/// User-authored Agent Plugin intent before the factory materializes plugin.json, SKILL.md, and guest code.
public struct PluginSkillDraft: Sendable, Hashable {
    public enum Trigger: String, Sendable, CaseIterable, Codable, Hashable {
        case chat
        case messaging
        case schedule
        case mention

        public var label: String {
            switch self {
            case .chat: return "When I ask in chat"
            case .messaging: return "From Messaging"
            case .schedule: return "On a schedule"
            case .mention: return "When I type /plugin-name"
            }
        }
    }

    public struct Example: Sendable, Hashable, Identifiable {
        public var id: String
        public var userSays: String
        public var pluginDoes: String

        public init(id: String = UUID().uuidString, userSays: String, pluginDoes: String) {
            self.id = id
            self.userSays = userSays
            self.pluginDoes = pluginDoes
        }
    }

    public enum PlannedKind: String, Sendable, Hashable {
        case messagingConnector
        case customCapability
    }

    public var goal: String
    public var purpose: String
    public var triggers: Set<Trigger>
    public var examples: [Example]
    public var pluginName: String

    public init(
        goal: String = "",
        purpose: String = "",
        triggers: Set<Trigger> = [.chat],
        examples: [Example] = [],
        pluginName: String = ""
    ) {
        self.goal = goal
        self.purpose = purpose
        self.triggers = triggers
        self.examples = examples
        self.pluginName = pluginName
    }

    public var plannedKind: PlannedKind {
        PluginSkillDraftPlanner.inferKind(from: self)
    }

    public var inferredConnectorVendor: PluginFactoryCreateInput.ConnectorVendor? {
        PluginSkillDraftPlanner.inferConnectorVendor(from: self)
    }

    public var isBuildable: Bool {
        switch plannedKind {
        case .messagingConnector:
            return inferredConnectorVendor?.isSelectableInWizard == true
        case .customCapability:
            return true
        }
    }

    public var buildBlockedReason: String? {
        if plannedKind == .messagingConnector,
           inferredConnectorVendor?.isSelectableInWizard != true {
            let label = inferredConnectorVendor?.displayName ?? "That service"
            return "\(label) messaging connectors are not available yet. Try Slack or describe a custom capability."
        }
        return nil
    }

    public func isTriggerAvailable(_ trigger: Trigger) -> Bool {
        PluginSkillDraftPlanner.availableTriggers(for: plannedKind).contains(trigger)
    }

    public func skillMarkdown() -> String {
        PluginSkillDraftPlanner.skillMarkdown(for: self)
    }

    public func previewScenarios() -> [String] {
        examples.map { example in
            "When you say “\(example.userSays)”, the plugin will \(example.pluginDoes)."
        }
    }

    public func packageOutline() -> [String] {
        switch plannedKind {
        case .messagingConnector, .customCapability:
            return [
                "plugin.json — name, permissions, and secrets",
                "skills/\(normalizedPluginFolderName())/SKILL.md — purpose and examples",
                "app.derrick/plugin.go — guest program (compiled in Docker)",
                "app.derrick/plugin — compiled binary",
            ]
        }
    }

    public func factoryDescription() -> String {
        PluginSkillDraftPlanner.factoryDescription(for: self)
    }

    public func normalizedPluginID() throws -> String {
        try PluginID.normalized(pluginName).rawValue
    }

    private func normalizedPluginFolderName() -> String {
        let trimmed = pluginName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "plugin" }
        return trimmed
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

public enum PluginSkillDraftPlanner {
    public static func availableTriggers(
        for kind: PluginSkillDraft.PlannedKind
    ) -> Set<PluginSkillDraft.Trigger> {
        switch kind {
        case .messagingConnector:
            return [.chat, .messaging, .mention]
        case .customCapability:
            return [.chat, .mention, .schedule]
        }
    }

    public static func sanitizeTriggers(in draft: inout PluginSkillDraft) {
        let allowed = availableTriggers(for: draft.plannedKind)
        draft.triggers = draft.triggers.intersection(allowed)
        if draft.triggers.isEmpty {
            draft.triggers = defaultTriggers(for: draft)
        }
    }

    public static func inferKind(from draft: PluginSkillDraft) -> PluginSkillDraft.PlannedKind {
        let text = combinedText(draft)
        if looksLikeMessaging(text) { return .messagingConnector }
        return .customCapability
    }

    public static func inferConnectorVendor(
        from draft: PluginSkillDraft
    ) -> PluginFactoryCreateInput.ConnectorVendor? {
        let text = combinedText(draft)
        if text.contains("slack") { return .slack }
        if text.contains("telegram") { return .telegram }
        if text.contains("whatsapp") { return .whatsapp }
        if text.contains("discord") { return .discord }
        if inferKind(from: draft) == .messagingConnector { return .slack }
        return nil
    }

    public static func applyGoal(_ goal: String, to draft: inout PluginSkillDraft, existingPluginIDs: [String]) {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.goal = trimmed
        if draft.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.purpose = trimmed
        }
        if draft.pluginName.isEmpty {
            draft.pluginName = suggestPluginName(for: draft, existingIDs: existingPluginIDs)
        }
        if draft.examples.isEmpty {
            draft.examples = defaultExamples(for: draft)
        }
        if draft.triggers.isEmpty {
            draft.triggers = defaultTriggers(for: draft)
        }
        sanitizeTriggers(in: &draft)
    }

    public static func skillMarkdown(for draft: PluginSkillDraft) -> String {
        let name = draft.pluginName.trimmingCharacters(in: .whitespacesAndNewlines)
        let triggerLines = draft.triggers.sorted { $0.rawValue < $1.rawValue }.map(\.label)
        let exampleBlock = draft.examples.map { example in
            """
            ### User
            \(example.userSays)

            ### Plugin
            \(example.pluginDoes)
            """
        }.joined(separator: "\n\n")

        return """
        # \(name.isEmpty ? "Plugin" : name)

        ## Purpose
        \(draft.purpose.trimmingCharacters(in: .whitespacesAndNewlines))

        ## When to use
        \(triggerLines.map { "- \($0)" }.joined(separator: "\n"))

        ## Examples
        \(exampleBlock.isEmpty ? "_Add at least one example before building._" : exampleBlock)
        """
    }

    public static func factoryDescription(for draft: PluginSkillDraft) -> String {
        let purpose = draft.purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        let examples = draft.examples
            .map { "User: \($0.userSays) → Plugin: \($0.pluginDoes)" }
            .joined(separator: "\n")
        switch draft.plannedKind {
        case .messagingConnector:
            let vendor = inferConnectorVendor(from: draft)?.displayName ?? "messaging"
            return """
            \(purpose)

            Messaging connector for \(vendor). List conversations as tabs, load messages including reply threads, and send messages.

            Confirmed behavior:
            \(examples)
            """
        case .customCapability:
            return """
            \(purpose)

            Confirmed behavior:
            \(examples)
            """
        }
    }

    public static func factoryGoal(
        for draft: PluginSkillDraft,
        crawlSummary: String?,
        hostNotes: [String]
    ) throws -> String {
        let description = factoryDescription(for: draft)
        switch draft.plannedKind {
        case .messagingConnector:
            guard let vendor = inferConnectorVendor(from: draft) else {
                throw PluginSkillDraftError.missingConnectorVendor
            }
            var extra = hostNotes
            extra.append("SKILL.md draft:\n\(skillMarkdown(for: draft))")
            return try ConnectorContractPrompts.factoryGoal(
                vendorLabel: vendor.displayName,
                scope: .fullSync,
                vendor: vendor,
                crawlSummary: crawlSummary,
                reference: extra.joined(separator: "\n"),
                includeVendorBindings: true
            )
        case .customCapability:
            return """
            Create an Agent Plugin for this user goal.

            \(description)

            Host notes:
            \(hostNotes.joined(separator: "\n"))

            SKILL.md draft (write this into skills/):
            \(skillMarkdown(for: draft))

            Return go_source, test_input_json, and skill_files. The host writes plugin.json when a host manifest is supplied; otherwise include a valid manifest in your output path via the builder contract.
            """
        }
    }

    private static func combinedText(_ draft: PluginSkillDraft) -> String {
        [draft.goal, draft.purpose, draft.pluginName]
            .joined(separator: " ")
            .lowercased()
    }

    private static func looksLikeMessaging(_ text: String) -> Bool {
        ["slack", "telegram", "whatsapp", "discord", "messaging", "channel", "inbox", "dm", "chat app"]
            .contains { text.contains($0) }
    }

    private static func suggestPluginName(for draft: PluginSkillDraft, existingIDs: [String]) -> String {
        switch inferKind(from: draft) {
        case .messagingConnector:
            if let vendor = inferConnectorVendor(from: draft) {
                return ConnectorPluginNaming.defaultPluginID(vendor: vendor, existingIDs: existingIDs)
            }
            return ConnectorPluginNaming.defaultPluginID(vendor: .slack, existingIDs: existingIDs)
        case .customCapability:
            let words = draft.goal
                .lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .filter { $0.count > 2 }
                .prefix(3)
            let stem = words.isEmpty ? "custom-plugin" : String(words.joined(separator: "-"))
            if !existingIDs.contains(stem) { return stem }
            return "\(stem)-2"
        }
    }

    private static func defaultTriggers(for draft: PluginSkillDraft) -> Set<PluginSkillDraft.Trigger> {
        switch inferKind(from: draft) {
        case .messagingConnector:
            return [.messaging, .chat]
        case .customCapability:
            return [.chat]
        }
    }

    private static func defaultExamples(for draft: PluginSkillDraft) -> [PluginSkillDraft.Example] {
        switch inferKind(from: draft) {
        case .messagingConnector:
            let vendor = inferConnectorVendor(from: draft)?.displayName ?? "Slack"
            return [
                PluginSkillDraft.Example(
                    userSays: "Show my \(vendor) channels",
                    pluginDoes: "list conversations you can access as tabs in Messaging"
                ),
                PluginSkillDraft.Example(
                    userSays: "Send “hello” to #general",
                    pluginDoes: "post the message in that channel"
                ),
            ]
        case .customCapability:
            let snippet = draft.goal.trimmingCharacters(in: .whitespacesAndNewlines)
            return [
                PluginSkillDraft.Example(
                    userSays: snippet.isEmpty ? "Do the thing I described" : snippet,
                    pluginDoes: "run the guest program and return a clear result"
                ),
            ]
        }
    }
}

public enum PluginSkillDraftError: Error, LocalizedError {
    case missingConnectorVendor
    case invalidPluginName

    public var errorDescription: String? {
        switch self {
        case .missingConnectorVendor:
            return "Could not determine which messaging service this plugin targets."
        case .invalidPluginName:
            return "Choose a valid plugin name using letters, numbers, and hyphens."
        }
    }
}
