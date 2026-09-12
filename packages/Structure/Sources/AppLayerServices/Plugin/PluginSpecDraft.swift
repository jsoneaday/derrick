import Foundation

/// Finite ontology slots. Empty means not buildable. Oracles are not slots.
public enum PluginSpecSlot: String, Sendable, Hashable, Codable, CaseIterable {
    case connect
    case access
    case work
    case returnPayload
    case trigger

    public var processionIndex: Int {
        switch self {
        case .connect: return 0
        case .access: return 1
        case .work: return 2
        case .returnPayload: return 3
        case .trigger: return 4
        }
    }
}

public enum PluginConnectClass: String, Sendable, Hashable, Codable {
    case namedSite
    case feed
    case localFiles
    case messagingInbox
    case installedApp
}

public enum PluginAccessState: String, Sendable, Hashable, Codable {
    case reachable
    case unreachable
}

public enum PluginWorkVerb: String, Sendable, Hashable, Codable {
    case fetch
    case summarize
    case list
    case send
    case search
    case watch
}

public enum PluginReturnClass: String, Sendable, Hashable, Codable {
    case message
    case list
    case brief
    case file
    case image
    case threadItems
}

public enum PluginTriggerClass: String, Sendable, Hashable, Codable {
    case chat
    case messaging
    case schedule
    case mention
}

public struct PluginConnectBinding: Sendable, Hashable, Codable {
    public var klass: PluginConnectClass
    public var detail: String

    public init(klass: PluginConnectClass, detail: String) {
        self.klass = klass
        self.detail = detail
    }
}

/// Spec filled by the plugin-creator procession. Present is bound by the host.
public struct PluginSpecDraft: Sendable, Hashable, Codable {
    public var claimedOutcome: String?
    public var connect: PluginConnectBinding?
    public var access: PluginAccessState?
    public var work: PluginWorkVerb?
    public var returnClass: PluginReturnClass?
    public var trigger: PluginTriggerClass?
    public var present: PluginPresent?
    public var presentSource: PluginPresentSource?
    public var wrongness: String?
    public var parked: [String: String]

    public init(
        claimedOutcome: String? = nil,
        connect: PluginConnectBinding? = nil,
        access: PluginAccessState? = nil,
        work: PluginWorkVerb? = nil,
        returnClass: PluginReturnClass? = nil,
        trigger: PluginTriggerClass? = nil,
        present: PluginPresent? = nil,
        presentSource: PluginPresentSource? = nil,
        wrongness: String? = nil,
        parked: [String: String] = [:]
    ) {
        self.claimedOutcome = claimedOutcome
        self.connect = connect
        self.access = access
        self.work = work
        self.returnClass = returnClass
        self.trigger = trigger
        self.present = present
        self.presentSource = presentSource
        self.wrongness = wrongness
        self.parked = parked
    }

    public var isMessagingConnect: Bool {
        connect?.klass == .messagingInbox
    }

    public var isBuildable: Bool {
        guard let claimedOutcome, !claimedOutcome.isEmpty else { return false }
        guard connect != nil else { return false }
        guard access == .reachable else { return false }
        guard work != nil, returnClass != nil, trigger != nil else { return false }
        guard present != nil else { return false }
        guard let wrongness, !wrongness.isEmpty else { return false }
        return true
    }

    public func asSkillDraft(pluginName: String = "") -> PluginSkillDraft {
        let outcome = claimedOutcome ?? ""
        var triggers: Set<PluginSkillDraft.Trigger> = [.chat]
        if let trigger {
            triggers = [Self.skillTrigger(trigger)]
        }
        let purposeParts = [
            outcome,
            connect.map { "Connect: \($0.klass.rawValue) \($0.detail)" },
            work.map { "Work: \($0.rawValue)" },
            returnClass.map { "Return: \($0.rawValue)" },
            present.map { "Present: \($0.rawValue)" },
        ].compactMap { $0 }
        return PluginSkillDraft(
            goal: outcome,
            purpose: purposeParts.joined(separator: ". "),
            triggers: triggers,
            examples: [
                PluginSkillDraft.Example(
                    userSays: outcome.isEmpty ? "Run this plugin" : outcome,
                    pluginDoes: "return \(returnClass?.rawValue ?? "a result") in the Chat tab"
                ),
            ],
            pluginName: pluginName
        )
    }

    private static func skillTrigger(_ trigger: PluginTriggerClass) -> PluginSkillDraft.Trigger {
        switch trigger {
        case .chat: return .chat
        case .messaging: return .messaging
        case .schedule: return .schedule
        case .mention: return .mention
        }
    }
}

public enum PluginCreatorSpecError: Error, LocalizedError, Equatable, Hashable {
    case notBuildable
    case accessUnreachable

    public var errorDescription: String? {
        switch self {
        case .notBuildable:
            return "This plugin is not ready to build until every spec slot and Present are bound."
        case .accessUnreachable:
            return "Derrick cannot reach that source yet, so the plugin cannot be built."
        }
    }
}
