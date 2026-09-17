import Foundation

/// Next thing the creator skill may ask. One legal ask at a time.
public enum PluginSpecAsk: Equatable, Sendable, Hashable {
    case claimedOutcome
    case slot(PluginSpecSlot)
    case docsURL
    case accessSecret
    case presentChoice
    case wrongness
    case complete
    case blocked(PluginCreatorSpecError)
}

public struct PluginSpecSession: Sendable, Hashable {
    public var draft: PluginSpecDraft
    public var ask: PluginSpecAsk
    /// Filled from vendor setup docs (or a known-vendor fallback) before Access is asked.
    public var accessDiscovery: ConnectorAuthDiscovery?
    /// Plugin id reserved when the credential form is shown, so factory matches Keychain.
    public var reservedPluginID: String?
    /// True after the host credential form stored the secrets.
    public var accessSecretsCollected: Bool

    public init(
        draft: PluginSpecDraft = PluginSpecDraft(),
        ask: PluginSpecAsk = .claimedOutcome,
        accessDiscovery: ConnectorAuthDiscovery? = nil,
        reservedPluginID: String? = nil,
        accessSecretsCollected: Bool = false
    ) {
        self.draft = draft
        self.ask = ask
        self.accessDiscovery = accessDiscovery
        self.reservedPluginID = reservedPluginID
        self.accessSecretsCollected = accessSecretsCollected
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
    public static let creatorTabIDPrefix = "plugin-creator"
    /// Chat tab title for the Plugins workspace (Create plugin + Plugins browser).
    public static let pluginsTabTitle = "Plugins"
    /// Label for the Create plugin subtab and seeded creator turn prompt.
    public static let creatorTabTitlePrefix = "Create plugin"
    public static let creatorTabTitleSnippetLimit = 42

    public static func isCreatorTabID(_ id: String) -> Bool {
        id == creatorTabID || id.hasPrefix(creatorTabIDPrefix + "-")
    }

    public static func newCreatorTabID() -> String {
        "\(creatorTabIDPrefix)-\(UUID().uuidString.lowercased())"
    }

    public static var openingQuestion: String {
        question(for: .claimedOutcome)
    }

    public static func creatorTabTitle(from description: String) -> String {
        let snippet = description
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !snippet.isEmpty else { return creatorTabTitlePrefix }
        if snippet.count <= creatorTabTitleSnippetLimit {
            return "\(creatorTabTitlePrefix) - \(snippet)"
        }
        return "\(creatorTabTitlePrefix) - \(snippet.prefix(creatorTabTitleSnippetLimit))..."
    }

    public static func question(for ask: PluginSpecAsk) -> String {
        question(for: ask, session: PluginSpecSession(ask: ask))
    }

    public static func question(for ask: PluginSpecAsk, session: PluginSpecSession) -> String {
        switch ask {
        case .claimedOutcome:
            return "What should this plugin do when it works?"
        case .slot(.connect):
            return "Where should that come from? A site, a feed, an app you already use, or files on this Mac?"
        case .docsURL:
            return PluginAccessAskPolicy.docsURLQuestion(
                triedURL: session.draft.documentationURL,
                fromHuman: session.draft.documentationURLFromHuman,
                failure: session.draft.docsLookupFailure
            )
        case .slot(.access):
            return PluginAccessAskPolicy.question(
                connect: session.draft.connect,
                discovery: session.accessDiscovery,
                documentationURL: session.draft.documentationURL
            )
        case .accessSecret:
            return PluginAccessAskPolicy.credentialFormQuestion(
                discovery: session.accessDiscovery
            )
        case .slot(.work):
            return "What should it do to that source? Fetch, summarize, list, send, search, or watch?"
        case .slot(.returnPayload):
            return "What should come back — a brief, a list, a message, a file, an image, or thread items?"
        case .slot(.trigger):
            return "How would you like to run this plugin? You can pick more than one: chat, a job or schedule, typing /name, or from messaging."
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
            return PluginSpecTurn(
                reply: question(for: session.ask, session: session),
                ask: session.ask,
                isComplete: false
            )
        }

        let askAtStart = session.ask
        parkLaterSlots(from: trimmed, onto: &session.draft)

        switch session.ask {
        case .claimedOutcome:
            session.draft.claimedOutcome = trimmed
            session.ask = nextAsk(&session.draft)
        case .docsURL:
            if let url = PluginAccessAskPolicy.parseHTTPURL(trimmed) {
                session.draft.documentationURL = url
                session.draft.documentationURLFromHuman = true
                session.draft.needsHumanDocsURL = false
                session.draft.docsLookupFailure = nil
                session.ask = .slot(.access)
            } else if PluginAccessAskPolicy.isDocsSearchRequest(trimmed) {
                session.draft.documentationURL = nil
                session.draft.documentationURLFromHuman = false
                session.draft.needsHumanDocsURL = false
                session.draft.docsLookupFailure = nil
                session.ask = .slot(.access)
            }
        case .slot(let slot):
            if slot == .access {
                switch bindAccess(from: trimmed, session: &session) {
                case .unbound:
                    break
                case .collectSecret:
                    session.draft.parked[PluginSpecSlot.access.rawValue] = nil
                    session.ask = .accessSecret
                case .bound:
                    session.draft.parked[slot.rawValue] = nil
                    session.ask = nextAsk(&session.draft)
                }
            } else if bind(slot, from: trimmed, onto: &session.draft) {
                session.draft.parked[slot.rawValue] = nil
                session.ask = nextAsk(&session.draft)
            }
        case .accessSecret:
            switch bindAccessSecret(from: trimmed, session: &session) {
            case .unbound:
                break
            case .collectSecret:
                session.ask = .accessSecret
            case .bound:
                session.draft.parked[PluginSpecSlot.access.rawValue] = nil
                session.ask = nextAsk(&session.draft)
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
                    session.ask = session.draft.isBuildable ? .complete : nextAsk(&session.draft)
                case .needsHumanChoice:
                    session.ask = .presentChoice
                }
            } else {
                session.ask = nextAsk(&session.draft)
            }
        case .complete, .blocked:
            break
        }

        if case .blocked = session.ask {
            return PluginSpecTurn(
                reply: question(for: session.ask, session: session),
                ask: session.ask,
                isComplete: false
            )
        }

        applyParkedBindings(&session)
        if session.ask == .complete || session.draft.isBuildable {
            session.ask = .complete
            return PluginSpecTurn(
                reply: question(for: .complete, session: session),
                ask: .complete,
                isComplete: true
            )
        }

        let reply: String
        if session.ask == askAtStart {
            reply = notBoundHint(for: session.ask, utterance: trimmed)
                ?? question(for: session.ask, session: session)
        } else {
            reply = question(for: session.ask, session: session)
        }
        return PluginSpecTurn(
            reply: reply,
            ask: session.ask,
            isComplete: false
        )
    }

    /// Host credential form finished. Mark Access reachable and continue the procession.
    public static func completeAccessCollection(session: inout PluginSpecSession) -> PluginSpecTurn {
        session.accessSecretsCollected = true
        session.draft.access = .reachable
        session.draft.parked[PluginSpecSlot.access.rawValue] = nil
        session.ask = nextAsk(&session.draft)
        applyParkedBindings(&session)
        if session.ask == .complete || session.draft.isBuildable {
            session.ask = .complete
            return PluginSpecTurn(
                reply: question(for: .complete, session: session),
                ask: .complete,
                isComplete: true
            )
        }
        return PluginSpecTurn(
            reply: question(for: session.ask, session: session),
            ask: session.ask,
            isComplete: false
        )
    }

    public static func nextAsk(_ draft: PluginSpecDraft) -> PluginSpecAsk {
        var copy = draft
        return nextAsk(&copy)
    }

    public static func nextAsk(_ draft: inout PluginSpecDraft) -> PluginSpecAsk {
        seedDocumentationURL(&draft)
        if draft.claimedOutcome?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return .claimedOutcome
        }
        if draft.connect == nil { return .slot(.connect) }
        if draft.access == nil {
            if draft.connect?.klass == .localFiles {
                return .slot(.access)
            }
            if draft.needsHumanDocsURL {
                return .docsURL
            }
            return .slot(.access)
        }
        if draft.access == .unreachable { return .blocked(.accessUnreachable) }
        if draft.work == nil { return .slot(.work) }
        if draft.returnClass == nil { return .slot(.returnPayload) }
        if draft.triggers.isEmpty { return .slot(.trigger) }
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

    private static func seedDocumentationURL(_ draft: inout PluginSpecDraft) {
        if draft.documentationURL == nil,
           let url = PluginAccessAskPolicy.documentationURL(from: draft.connect) {
            draft.documentationURL = url
            draft.documentationURLFromHuman = true
        }
    }

    public static func resolvedDocumentationURL(_ draft: PluginSpecDraft) -> String? {
        let stored = draft.documentationURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty { return stored }
        return PluginAccessAskPolicy.documentationURL(from: draft.connect)
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
        if session.ask == .accessSecret {
            bindInferredPresent(onto: &session.draft)
            return
        }
        bindInferredPresent(onto: &session.draft)
        var progressed = true
        while progressed {
            progressed = false
            let ask = nextAsk(&session.draft)
            if case .slot(let slot) = ask, let parked = session.draft.parked[slot.rawValue],
               bind(slot, from: parked, onto: &session.draft) {
                session.draft.parked[slot.rawValue] = nil
                progressed = true
            }
            bindInferredPresent(onto: &session.draft)
        }
        session.ask = nextAsk(&session.draft)
        bindInferredPresent(onto: &session.draft)
        session.ask = nextAsk(&session.draft)
    }

    private static func parkLaterSlots(from text: String, onto draft: inout PluginSpecDraft) {
        let later: [PluginSpecSlot] = [.connect, .access, .work, .returnPayload, .trigger]
        for slot in later {
            if extract(slot, from: text) != nil {
                draft.parked[slot.rawValue] = text
            }
        }
    }

    private enum AccessBind: Equatable {
        case unbound
        case collectSecret
        case bound
    }

    private static func bindAccess(
        from text: String,
        session: inout PluginSpecSession
    ) -> AccessBind {
        guard let access = PluginSpecClassifier.access(from: text) else { return .unbound }
        if access == .reachable,
           PluginAccessAskPolicy.needsCredentialForm(session.accessDiscovery),
           !session.accessSecretsCollected {
            return .collectSecret
        }
        session.draft.access = access
        return .bound
    }

    private static func bindAccessSecret(
        from text: String,
        session: inout PluginSpecSession
    ) -> AccessBind {
        if let access = PluginSpecClassifier.access(from: text), access == .unreachable {
            session.draft.access = .unreachable
            return .bound
        }
        return .unbound
    }

    @discardableResult
    private static func bind(
        _ slot: PluginSpecSlot,
        from text: String,
        onto draft: inout PluginSpecDraft
    ) -> Bool {
        switch slot {
        case .connect:
            guard let binding = PluginSpecClassifier.connect(
                from: text,
                allowingUnknownName: true
            ) else { return false }
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
            let found = PluginSpecClassifier.triggers(from: text)
            guard !found.isEmpty else { return false }
            draft.triggers.formUnion(found)
            return true
        }
    }

    private static func extract(_ slot: PluginSpecSlot, from text: String) -> Bool? {
        switch slot {
        case .connect:
            return PluginSpecClassifier.connect(from: text, allowingUnknownName: false) != nil
                ? true : nil
        case .access: return PluginSpecClassifier.access(from: text) != nil ? true : nil
        case .work: return PluginSpecClassifier.work(from: text) != nil ? true : nil
        case .returnPayload: return PluginSpecClassifier.returnClass(from: text) != nil ? true : nil
        case .trigger: return PluginSpecClassifier.triggers(from: text).isEmpty ? nil : true
        }
    }

    private static func notBoundHint(for ask: PluginSpecAsk, utterance: String) -> String? {
        if case .docsURL = ask, PluginAccessAskPolicy.parseHTTPURL(utterance) == nil {
            if PluginAccessAskPolicy.isDocsSearchRequest(utterance) {
                return nil
            }
            return "That does not look like a web address. Paste the full http or https link to the API setup docs, or ask Derrick to search for them."
        }
        if case .accessSecret = ask {
            return "Enter the token or key in the form Derrick opened. It stays on this Mac."
        }
        if case .slot(.connect) = ask, PluginSpecClassifier.connect(
            from: utterance,
            allowingUnknownName: true
        ) == nil {
            if PluginSpecClassifier.isUnnamedService(utterance) {
                return "Name the app or site Derrick should use. Inbox, chat, or “an API” is not enough."
            }
            return "That is not a place Derrick can open. Name a site, a feed, files on this Mac, or an app you already use."
        }
        if case .slot(.trigger) = ask, PluginSpecClassifier.triggers(from: utterance).isEmpty {
            return "You can pick more than one: chat, a job or schedule, typing /name, or from messaging."
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
    static func connect(
        from text: String,
        allowingUnknownName: Bool = false
    ) -> PluginConnectBinding? {
        let lowered = text.lowercased()
        if isVaguePlace(lowered) {
            return nil
        }
        if lowered.contains("this mac") || lowered.contains("local file")
            || lowered.contains("files on") || lowered.contains("folder") {
            return PluginConnectBinding(klass: .localFiles, detail: text)
        }
        if lowered.contains("rss") || lowered.contains("atom") || lowered.contains("feed") {
            return PluginConnectBinding(klass: .feed, detail: text)
        }
        if lowered.contains("http://") || lowered.contains("https://")
            || lowered.contains("google news") || lowered.contains("wall street journal")
            || looksLikeNamedSite(lowered) {
            return PluginConnectBinding(klass: .namedSite, detail: text)
        }
        if isKnownMessagingVendor(lowered) {
            return PluginConnectBinding(klass: .messagingInbox, detail: text)
        }
        if isUnnamedService(lowered) {
            return nil
        }
        if allowingUnknownName, hasDistinctiveSourceName(text) {
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

    static func triggers(from text: String) -> Set<PluginTriggerClass> {
        let lowered = text.lowercased()
        if isAllListedTriggers(lowered) {
            return Set(PluginTriggerClass.allCases)
        }
        var found: Set<PluginTriggerClass> = []
        if lowered.contains("schedule") || lowered.contains("every day")
            || lowered.contains("daily") || lowered.contains("job") {
            found.insert(.schedule)
        }
        if lowered.contains("messaging") || lowered.contains("from slack")
            || lowered.contains("from a channel") {
            found.insert(.messaging)
        }
        if lowered.contains("/name") || lowered.contains("slash")
            || lowered.contains("when i type /") || lowered.contains("type /")
            || lowered.contains("direct /") || lowered.contains("'/") {
            found.insert(.mention)
        }
        if lowered.contains("chat") || lowered.contains("when i ask") {
            found.insert(.chat)
        }
        return found
    }

    private static func isAllListedTriggers(_ lowered: String) -> Bool {
        let collapsed = lowered
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet.punctuationCharacters)
        if collapsed == "all" || collapsed == "all please" || collapsed == "everything" {
            return true
        }
        let needles = [
            "all of the ones",
            "all the ones you listed",
            "the ones you listed",
            "ones you listed",
            "all of them",
            "all of those",
            "all of the above",
            "all three",
            "all four",
            "all the ways",
            "every way",
            "both",
        ]
        return needles.contains { lowered.contains($0) }
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

    static func isUnnamedService(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if isVaguePlace(lowered) { return false }
        if isKnownMessagingVendor(lowered) { return false }
        if PluginAccessAskPolicy.parseHTTPURL(text) != nil { return false }
        if looksLikeNamedSite(lowered) { return false }
        if lowered.contains("this mac") || lowered.contains("local file")
            || lowered.contains("files on") || lowered.contains("folder")
            || lowered.contains("rss") || lowered.contains("atom") || lowered.contains("feed") {
            return false
        }
        return !hasDistinctiveSourceName(text)
    }

    private static func isKnownMessagingVendor(_ lowered: String) -> Bool {
        lowered.contains("slack")
            || lowered.contains("telegram")
            || lowered.contains("whatsapp")
            || lowered.contains("discord")
    }

    private static func hasDistinctiveSourceName(_ text: String) -> Bool {
        let tokens = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return tokens.contains { token in
            token.count >= 3 && !sourceNameStopWords.contains(token)
        }
    }

    private static let sourceNameStopWords: Set<String> = [
        "the", "a", "an", "my", "our", "that", "this", "those", "these",
        "app", "apps", "service", "vendor", "api", "inbox", "chat", "messaging",
        "tool", "tools", "work", "site", "website", "source", "place", "thing",
        "one", "from", "with", "for", "and", "or", "to", "of", "in", "on", "at",
        "already", "use", "using", "connect", "connected", "login", "account",
        "messages", "message", "channel", "channels", "bot",
    ]

    private static func looksLikeNamedSite(_ lowered: String) -> Bool {
        lowered.contains("news") && (lowered.contains("google") || lowered.contains(".com") || lowered.contains("journal"))
            || lowered.contains("nytimes")
            || lowered.contains("wall street")
    }
}
