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

public enum PluginTriggerClass: String, Sendable, Hashable, Codable, CaseIterable {
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
    public var triggers: Set<PluginTriggerClass>
    public var present: PluginPresent?
    public var presentSource: PluginPresentSource?
    public var wrongness: String?
    public var parked: [String: String]
    /// API setup docs to crawl before Access. Empty means Derrick must ask for a URL.
    public var documentationURL: String?
    /// True when a crawl ran and did not yield usable setup notes.
    public var needsHumanDocsURL: Bool
    /// True when `documentationURL` came from a paste, not from Derrick's search.
    public var documentationURLFromHuman: Bool
    /// Why the last docs lookup failed. Used for honest Access copy.
    public var docsLookupFailure: PluginDocsLookupFailure?

    public init(
        claimedOutcome: String? = nil,
        connect: PluginConnectBinding? = nil,
        access: PluginAccessState? = nil,
        work: PluginWorkVerb? = nil,
        returnClass: PluginReturnClass? = nil,
        triggers: Set<PluginTriggerClass> = [],
        present: PluginPresent? = nil,
        presentSource: PluginPresentSource? = nil,
        wrongness: String? = nil,
        parked: [String: String] = [:],
        documentationURL: String? = nil,
        needsHumanDocsURL: Bool = false,
        documentationURLFromHuman: Bool = false,
        docsLookupFailure: PluginDocsLookupFailure? = nil
    ) {
        self.claimedOutcome = claimedOutcome
        self.connect = connect
        self.access = access
        self.work = work
        self.returnClass = returnClass
        self.triggers = triggers
        self.present = present
        self.presentSource = presentSource
        self.wrongness = wrongness
        self.parked = parked
        self.documentationURL = documentationURL
        self.needsHumanDocsURL = needsHumanDocsURL
        self.documentationURLFromHuman = documentationURLFromHuman
        self.docsLookupFailure = docsLookupFailure
    }

    public var isMessagingConnect: Bool {
        connect?.klass == .messagingInbox
    }

    public var isBuildable: Bool {
        guard let claimedOutcome, !claimedOutcome.isEmpty else { return false }
        guard connect != nil else { return false }
        guard access == .reachable else { return false }
        guard work != nil, returnClass != nil, !triggers.isEmpty else { return false }
        guard present != nil else { return false }
        guard let wrongness, !wrongness.isEmpty else { return false }
        return true
    }

    public func asSkillDraft(pluginName: String = "") -> PluginSkillDraft {
        let outcome = claimedOutcome ?? ""
        var draftCopy = self
        PluginSpecProcession.bindInferredTriggers(onto: &draftCopy)
        let skillTriggers = Set(draftCopy.triggers.map(Self.skillTrigger))
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
            triggers: skillTriggers.isEmpty ? [.chat] : skillTriggers,
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
