import Foundation

/// Next thing the creator skill may ask. One legal ask at a time.
public enum PluginSpecAsk: Equatable, Sendable, Hashable {
    case claimedOutcome
    case slot(PluginSpecSlot)
    case presentChoice
    case wrongness
    case complete
    case blocked(PluginCreatorSpecError)
}

public struct PluginSpecSession: Sendable, Hashable {
    public var draft: PluginSpecDraft
    public var ask: PluginSpecAsk

    public init(draft: PluginSpecDraft = PluginSpecDraft(), ask: PluginSpecAsk = .claimedOutcome) {
        self.draft = draft
        self.ask = ask
    }
}

public struct PluginSpecTurn: Equatable, Sendable {
    public var reply: String
    public var ask: PluginSpecAsk
    public var isComplete: Bool

    public init(reply: String, ask: PluginSpecAsk, isComplete: Bool) {
        self.reply = reply
        self.ask = ask
        self.isComplete = isComplete
    }
}

/// Procession: ask only the next unfilled legal slot. Received means bound, not merely spoken.
public enum PluginSpecProcession: Sendable {
    public static let creatorTabID = "plugin-creator"

    public static var openingQuestion: String {
        question(for: .claimedOutcome)
    }

    public static func question(for ask: PluginSpecAsk) -> String {
        switch ask {
        case .claimedOutcome:
            return "What should this plugin do when it works?"
        case .slot(.connect):
            return "Where should that come from? A site, a feed, an app you already use, or files on this Mac?"
        case .slot(.access):
            return "Can Derrick reach that now, or is it blocked (login, paywall, or missing files)?"
        case .slot(.work):
            return "What should it do to that source? Fetch, summarize, list, send, search, or watch?"
        case .slot(.returnPayload):
            return "What should come back — a brief, a list, a message, a file, an image, or thread items?"
        case .slot(.trigger):
            return "When should it run — when you ask in chat, on a schedule, when you type /name, or from messaging?"
        case .presentChoice:
            return "In this chat tab, should this show as readable text, a view you can scan, or a file?"
        case .wrongness:
            return "What would make this the wrong plugin? What must not happen?"
        case .complete:
            return "The spec is bound. Derrick can build this plugin."
        case .blocked(.accessUnreachable):
            return "Derrick cannot reach that source yet, so this plugin cannot be built."
        case .blocked:
            return "This plugin is not ready to build."
        }
    }

    public static func advance(session: inout PluginSpecSession, utterance: String) -> PluginSpecTurn {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return PluginSpecTurn(reply: question(for: session.ask), ask: session.ask, isComplete: false)
        }

        parkLaterSlots(from: trimmed, onto: &session.draft)

        switch session.ask {
        case .claimedOutcome:
            session.draft.claimedOutcome = trimmed
            session.ask = nextAsk(session.draft)
        case .slot(let slot):
            if bind(slot, from: trimmed, onto: &session.draft) {
                session.draft.parked[slot.rawValue] = nil
                session.ask = nextAsk(session.draft)
            }
        case .presentChoice:
            if let present = PluginPresentPolicy.presentFromChoice(trimmed) {
                session.draft.present = present
                session.draft.presentSource = .asked
                session.ask = .wrongness
            }
        case .wrongness:
            session.draft.wrongness = trimmed
            if let current = session.draft.present {
                switch PluginPresentPolicy.applyWrongness(trimmed, current: current) {
                case .decided(let next):
                    if next != current {
                        session.draft.present = next
                        session.draft.presentSource = .wrongnessOverride
                    }
                    session.ask = session.draft.isBuildable ? .complete : nextAsk(session.draft)
                case .needsHumanChoice:
                    session.ask = .presentChoice
                }
            } else {
                session.ask = nextAsk(session.draft)
            }
        case .complete, .blocked:
            break
        }

        if case .blocked = session.ask {
            return PluginSpecTurn(
                reply: question(for: session.ask),
                ask: session.ask,
                isComplete: false
            )
        }

        applyParkedBindings(&session)
        if session.ask == .complete || session.draft.isBuildable {
            session.ask = .complete
            return PluginSpecTurn(
                reply: question(for: .complete),
                ask: .complete,
                isComplete: true
            )
        }

        return PluginSpecTurn(
            reply: notBoundHint(for: session.ask, utterance: trimmed) ?? question(for: session.ask),
            ask: session.ask,
            isComplete: false
        )
    }

    public static func nextAsk(_ draft: PluginSpecDraft) -> PluginSpecAsk {
        if draft.claimedOutcome?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return .claimedOutcome
        }
        if draft.connect == nil { return .slot(.connect) }
        if draft.access == nil { return .slot(.access) }
        if draft.access == .unreachable { return .blocked(.accessUnreachable) }
        if draft.work == nil { return .slot(.work) }
        if draft.returnClass == nil { return .slot(.returnPayload) }
        if draft.trigger == nil { return .slot(.trigger) }
        if draft.present == nil {
            if case .needsHumanChoice = PluginPresentPolicy.bind(spec: draft) {
                return .presentChoice
            }
            return .wrongness
        }
        if draft.wrongness?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return .wrongness
        }
        return draft.isBuildable ? .complete : .blocked(.notBuildable)
    }

    /// Host binds Present after Return (and Trigger) without asking, unless tied.
    public static func bindInferredPresent(onto draft: inout PluginSpecDraft) {
        guard draft.present == nil, draft.returnClass != nil else { return }
        switch PluginPresentPolicy.bind(spec: draft) {
        case .decided(let present):
            draft.present = present
            draft.presentSource = .inferred
        case .needsHumanChoice:
            break
        }
    }

    private static func applyParkedBindings(_ session: inout PluginSpecSession) {
        bindInferredPresent(onto: &session.draft)
        var progressed = true
        while progressed {
            progressed = false
            let ask = nextAsk(session.draft)
            if case .slot(let slot) = ask, let parked = session.draft.parked[slot.rawValue],
               bind(slot, from: parked, onto: &session.draft) {
                session.draft.parked[slot.rawValue] = nil
                progressed = true
            }
            bindInferredPresent(onto: &session.draft)
        }
        session.ask = nextAsk(session.draft)
        bindInferredPresent(onto: &session.draft)
        session.ask = nextAsk(session.draft)
    }

    private static func parkLaterSlots(from text: String, onto draft: inout PluginSpecDraft) {
        let later: [PluginSpecSlot] = [.connect, .access, .work, .returnPayload, .trigger]
        for slot in later {
            if extract(slot, from: text) != nil {
                draft.parked[slot.rawValue] = text
            }
        }
    }

    @discardableResult
    private static func bind(
        _ slot: PluginSpecSlot,
        from text: String,
        onto draft: inout PluginSpecDraft
    ) -> Bool {
        switch slot {
        case .connect:
            guard let binding = PluginSpecClassifier.connect(from: text) else { return false }
            draft.connect = binding
            return true
        case .access:
            guard let access = PluginSpecClassifier.access(from: text) else { return false }
            draft.access = access
            return true
        case .work:
            guard let work = PluginSpecClassifier.work(from: text) else { return false }
            draft.work = work
            return true
        case .returnPayload:
            guard let payload = PluginSpecClassifier.returnClass(from: text) else { return false }
            draft.returnClass = payload
            return true
        case .trigger:
            guard let trigger = PluginSpecClassifier.trigger(from: text) else { return false }
            draft.trigger = trigger
            return true
        }
    }

    private static func extract(_ slot: PluginSpecSlot, from text: String) -> Bool? {
        switch slot {
        case .connect: return PluginSpecClassifier.connect(from: text) != nil ? true : nil
        case .access: return PluginSpecClassifier.access(from: text) != nil ? true : nil
        case .work: return PluginSpecClassifier.work(from: text) != nil ? true : nil
        case .returnPayload: return PluginSpecClassifier.returnClass(from: text) != nil ? true : nil
        case .trigger: return PluginSpecClassifier.trigger(from: text) != nil ? true : nil
        }
    }

    private static func notBoundHint(for ask: PluginSpecAsk, utterance: String) -> String? {
        if case .slot(.connect) = ask, PluginSpecClassifier.connect(from: utterance) == nil {
            return "That is not a place Derrick can open. Name a site, a feed, files on this Mac, or an app you already use."
        }
        return nil
    }

    public static let creatorSkillMarkdown = """
    # Plugin creator

    You fill a finite spec. Ask only the next unfilled legal slot. Received means bound, not merely spoken.

    Slots, in order: Connect, Access, Work, Return, Trigger.
    Oracles, not slots: claimed outcome (first), wrongness (last).
    Present is bound by the host after Return. Do not ask for Present unless the host cannot decide.

    Park volunteered later answers. Do not jump ahead.
    """
}

enum PluginSpecClassifier {
    static func connect(from text: String) -> PluginConnectBinding? {
        let lowered = text.lowercased()
        if isVaguePlace(lowered) {
            return nil
        }
        if lowered.contains("slack") || lowered.contains("telegram")
            || lowered.contains("whatsapp") || lowered.contains("discord")
            || lowered.contains("inbox") {
            return PluginConnectBinding(klass: .messagingInbox, detail: text)
        }
        if lowered.contains("rss") || lowered.contains("atom") || lowered.contains("feed") {
            return PluginConnectBinding(klass: .feed, detail: text)
        }
        if lowered.contains("this mac") || lowered.contains("local file")
            || lowered.contains("files on") || lowered.contains("folder") {
            return PluginConnectBinding(klass: .localFiles, detail: text)
        }
        if lowered.contains("http://") || lowered.contains("https://")
            || lowered.contains("google news") || lowered.contains("wall street journal")
            || looksLikeNamedSite(lowered) {
            return PluginConnectBinding(klass: .namedSite, detail: text)
        }
        if lowered.contains("app i") || lowered.contains("app you already") {
            return PluginConnectBinding(klass: .installedApp, detail: text)
        }
        return nil
    }

    static func access(from text: String) -> PluginAccessState? {
        let lowered = text.lowercased()
        if lowered.contains("paywall") || lowered.contains("can't") || lowered.contains("cannot")
            || lowered.contains("blocked") || lowered.contains("no login")
            || lowered.contains("don't have") || lowered.contains("do not have") {
            return .unreachable
        }
        if lowered.contains("yes") || lowered.contains("public") || lowered.contains("can open")
            || lowered.contains("reachable") || lowered.contains("i have") || lowered.contains("logged in") {
            return .reachable
        }
        return nil
    }

    static func work(from text: String) -> PluginWorkVerb? {
        let lowered = text.lowercased()
        if lowered.contains("summar") { return .summarize }
        if lowered.contains("send") || lowered.contains("post") { return .send }
        if lowered.contains("list") || lowered.contains("show my") { return .list }
        if lowered.contains("watch") || lowered.contains("monitor") { return .watch }
        if lowered.contains("search") { return .search }
        if lowered.contains("fetch") || lowered.contains("get ") || lowered.contains("download") {
            return .fetch
        }
        return nil
    }

    static func returnClass(from text: String) -> PluginReturnClass? {
        let lowered = text.lowercased()
        if lowered.contains("thread") || lowered.contains("channel list") {
            return .threadItems
        }
        if lowered.contains("image") || lowered.contains("picture") || lowered.contains("screenshot") {
            return .image
        }
        if lowered.contains("file") || lowered.contains("pdf") || lowered.contains("document") {
            return .file
        }
        if lowered.contains("list") || lowered.contains("headlines") || lowered.contains("many stor") {
            return .list
        }
        if lowered.contains("summar") || lowered.contains("brief") {
            return .brief
        }
        if lowered.contains("message") || lowered.contains("reply") || lowered.contains("tell me") {
            return .message
        }
        return nil
    }

    static func trigger(from text: String) -> PluginTriggerClass? {
        let lowered = text.lowercased()
        if lowered.contains("schedule") || lowered.contains("every day") || lowered.contains("daily") {
            return .schedule
        }
        if lowered.contains("messaging") || lowered.contains("from slack") {
            return .messaging
        }
        if lowered.contains("/name") || lowered.contains("slash") || lowered.contains("when i type /") {
            return .mention
        }
        if lowered.contains("chat") || lowered.contains("when i ask") {
            return .chat
        }
        return nil
    }

    private static func isVaguePlace(_ lowered: String) -> Bool {
        let collapsed = lowered.trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed == "the internet" || collapsed == "internet" || collapsed == "online"
            || collapsed == "the web" || collapsed == "google" || collapsed == "just google"
            || collapsed == "google is fine" {
            return true
        }
        if collapsed.contains("the internet") && !looksLikeNamedSite(collapsed) {
            return true
        }
        return false
    }

    private static func looksLikeNamedSite(_ lowered: String) -> Bool {
        lowered.contains("news") && (lowered.contains("google") || lowered.contains(".com") || lowered.contains("journal"))
            || lowered.contains("nytimes")
            || lowered.contains("wall street")
    }
}
