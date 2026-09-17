import Foundation
import Testing
@testable import Structure

@Suite struct PluginSpecProcessionTests {
    @Test func unnamedServiceAsksForTheAppName() {
        var session = PluginSpecSession()
        _ = PluginSpecProcession.advance(session: &session, utterance: "Read my work messages")
        let turn = PluginSpecProcession.advance(session: &session, utterance: "the inbox")
        #expect(session.draft.connect == nil)
        #expect(session.ask == .slot(.connect))
        #expect(turn.reply.contains("Name the app"))
    }

    @Test func misspelledVendorNameStillBindsConnectForDocsSearch() {
        var session = PluginSpecSession()
        _ = PluginSpecProcession.advance(session: &session, utterance: "Send messages")
        _ = PluginSpecProcession.advance(session: &session, utterance: "slak")
        #expect(session.draft.connect?.klass == .namedSite)
        #expect(session.draft.connect?.detail.lowercased().contains("slak") == true)
        #expect(session.ask == .slot(.access))
        let query = VendorDocsLocator.searchQuery(sourceName: session.draft.connect?.detail ?? "")
        #expect(query.contains("slak"))
    }

    @Test func internetDoesNotBindConnect() {
        var session = PluginSpecSession()
        _ = PluginSpecProcession.advance(session: &session, utterance: "Summaries of today’s tech news.")
        #expect(session.ask == .slot(.connect))
        let turn = PluginSpecProcession.advance(session: &session, utterance: "Just the internet. Google is fine.")
        #expect(session.draft.connect == nil)
        #expect(session.ask == .slot(.connect))
        #expect(turn.reply.contains("not a place"))
    }

    @Test func parksReturnFromClaimedOutcomeButDoesNotSkipConnect() {
        var session = PluginSpecSession()
        _ = PluginSpecProcession.advance(session: &session, utterance: "Give me summaries of today’s tech news.")
        #expect(session.draft.claimedOutcome != nil)
        #expect(session.ask == .slot(.connect))
        #expect(session.draft.parked[PluginSpecSlot.returnPayload.rawValue] != nil)
    }

    @Test func namedSiteBindsConnectThenReviewsDocs() {
        var session = PluginSpecSession()
        _ = PluginSpecProcession.advance(session: &session, utterance: "Summaries of tech news")
        _ = PluginSpecProcession.advance(session: &session, utterance: "Google News, and also the Wall Street Journal.")
        #expect(session.draft.connect?.klass == .namedSite)
        #expect(session.ask == .slot(.access))
        #expect(session.draft.documentationURL == nil)
    }

    @Test func unreachableAccessBlocksBuild() {
        var session = PluginSpecSession()
        _ = PluginSpecProcession.advance(session: &session, utterance: "Fetch files")
        _ = PluginSpecProcession.advance(session: &session, utterance: "files on this Mac")
        let turn = PluginSpecProcession.advance(session: &session, utterance: "paywall, I cannot open them")
        #expect(session.draft.access == .unreachable)
        #expect(turn.ask == .blocked(.accessUnreachable))
        #expect(session.draft.isBuildable == false)
    }

    @Test func completeSpecInfersConversationPresent() {
        var session = PluginSpecSession()
        _ = PluginSpecProcession.advance(session: &session, utterance: "A short brief of my notes")
        _ = PluginSpecProcession.advance(session: &session, utterance: "files on this Mac")
        _ = PluginSpecProcession.advance(session: &session, utterance: "yes I can open them")
        _ = PluginSpecProcession.advance(session: &session, utterance: "summarize them")
        _ = PluginSpecProcession.advance(session: &session, utterance: "a brief")
        _ = PluginSpecProcession.advance(session: &session, utterance: "when I ask in chat")
        #expect(session.draft.present == .conversation)
        #expect(session.draft.presentSource == .inferred)
        #expect(session.ask == .wrongness)
        let done = PluginSpecProcession.advance(session: &session, utterance: "nothing, that is fine")
        #expect(done.isComplete)
        #expect(session.draft.isBuildable)
    }

    @Test func slackConnectInfersThreadPresent() {
        var session = PluginSpecSession()
        _ = PluginSpecProcession.advance(session: &session, utterance: "Read my Slack inbox")
        _ = PluginSpecProcession.advance(session: &session, utterance: "Slack")
        _ = PluginSpecProcession.advance(session: &session, utterance: "yes I am logged in")
        _ = PluginSpecProcession.advance(session: &session, utterance: "list my channels")
        _ = PluginSpecProcession.advance(session: &session, utterance: "thread items")
        _ = PluginSpecProcession.advance(session: &session, utterance: "from messaging")
        #expect(session.draft.present == .thread)
        #expect(session.draft.triggers == [.messaging])
    }

    @Test func triggerAcceptsEveryListedWayToCallThePlugin() {
        var session = PluginSpecSession()
        session.ask = .slot(.trigger)
        session.draft.claimedOutcome = "Slack"
        session.draft.connect = PluginConnectBinding(klass: .messagingInbox, detail: "Slack")
        session.draft.access = .reachable
        session.draft.work = .send
        session.draft.returnClass = .message
        let turn = PluginSpecProcession.advance(
            session: &session,
            utterance: "all of the ones you listed"
        )
        #expect(session.draft.triggers == Set(PluginTriggerClass.allCases))
        #expect(session.ask != .slot(.trigger))
        #expect(turn.reply.contains("not ready") == false)
    }

    @Test func triggerAcceptsChatAndSlashTogether() {
        var session = PluginSpecSession()
        session.ask = .slot(.trigger)
        session.draft.claimedOutcome = "Notes"
        session.draft.connect = PluginConnectBinding(klass: .localFiles, detail: "files on this Mac")
        session.draft.access = .reachable
        session.draft.work = .summarize
        session.draft.returnClass = .brief
        _ = PluginSpecProcession.advance(
            session: &session,
            utterance: "when I ask in chat and when I type /name"
        )
        #expect(session.draft.triggers == [.chat, .mention])
    }

    @Test func allThreeSoundsGoodBindsEveryTrigger() {
        #expect(
            PluginSpecClassifier.triggers(from: "all")
                == Set(PluginTriggerClass.allCases)
        )
        #expect(
            PluginSpecClassifier.triggers(from: "all three sounds good")
                == Set(PluginTriggerClass.allCases)
        )
        #expect(
            PluginSpecClassifier.triggers(from: "job, direct /, and chat")
                == [.schedule, .mention, .chat]
        )
    }

    @Test func slackScreenshotConversationBindsEveryTriggerAndDoesNotRepeatTheAsk() {
        var session = PluginSpecSession()
        let afterGoal = PluginSpecProcession.advance(
            session: &session,
            utterance: "connect to slack and send and receive messages"
        )
        #expect(session.ask == .slot(.access))
        #expect(session.accessDiscovery == nil)
        #expect(afterGoal.reply == PluginAccessAskPolicy.reviewingQuestion)

        session.accessDiscovery = ConnectorAuthDiscovery(
            authScheme: .botToken,
            secrets: [PluginSecretField.slackBotToken],
            setupHint: "Slack apps authenticate with a bot token that can read and send messages.",
            crawlSummary: "Bot tokens are created in the Slack API dashboard."
        )
        session.draft.documentationURL = "https://docs.example.com/auth/tokens"
        let accessAsk = PluginSpecProcession.question(for: .slot(.access), session: session)
        #expect(accessAsk.contains("bot token"))
        #expect(accessAsk.contains("https://docs.example.com/auth/tokens"))
        #expect(accessAsk.contains(PluginAccessAskPolicy.reviewingQuestion) == false)

        let afterAccess = PluginSpecProcession.advance(
            session: &session,
            utterance: "it needs a bot key which I have"
        )
        #expect(session.ask == .accessSecret)
        #expect(session.draft.access == nil)
        #expect(afterAccess.reply.lowercased().contains("paste") == false)
        #expect(afterAccess.reply.lowercased().contains("form"))
        #expect(afterAccess.reply.lowercased().contains("bot token"))
        #expect(PluginAccessAskPolicy.credentialFormPrompt(discovery: session.accessDiscovery)
            .lowercased().contains("bot token"))
        #expect(PluginAccessAskPolicy.credentialFormPrompt(discovery: session.accessDiscovery)
            .lowercased().contains("never goes into the plugin"))

        let pastedInChat = PluginSpecProcession.advance(
            session: &session,
            utterance: "xoxb-example"
        )
        #expect(session.accessSecretsCollected == false)
        #expect(session.draft.access == nil)
        #expect(session.ask == .accessSecret)
        #expect(pastedInChat.reply.lowercased().contains("form"))

        let afterForm = PluginSpecProcession.completeAccessCollection(session: &session)
        #expect(session.accessSecretsCollected)
        #expect(session.draft.access == .reachable)
        #expect(session.ask == .slot(.trigger))
        #expect(afterForm.reply == "How would you like to run this plugin? You can pick more than one: chat, a job or schedule, typing /name, or from messaging.")
        #expect(afterForm.reply.contains("job/schedule") == false)

        let unclear = PluginSpecProcession.advance(session: &session, utterance: "whatever you think")
        #expect(session.ask == .slot(.trigger))
        #expect(unclear.reply == "You can pick more than one: chat, a job or schedule, typing /name, or from messaging.")
        #expect(unclear.reply.contains("job/schedule") == false)

        let bound = PluginSpecProcession.advance(session: &session, utterance: "all three sounds good")
        #expect(session.draft.triggers == Set(PluginTriggerClass.allCases))
        #expect(session.ask != .slot(.trigger))
        #expect(bound.reply != PluginSpecProcession.question(for: .slot(.trigger)))
        #expect(bound.reply != unclear.reply)
    }

    @Test func creatorTabTitleUsesDescriptionAndTruncates() {
        #expect(
            PluginSpecProcession.creatorTabTitle(from: "connect to slack")
                == "Create plugin - connect to slack"
        )
        #expect(PluginSpecProcession.pluginsTabTitle == "Plugins")
        let long = "connect to slack and send and receive messages extra words"
        let title = PluginSpecProcession.creatorTabTitle(from: long)
        #expect(title.hasPrefix("Create plugin - "))
        #expect(title.hasSuffix("..."))
        let snippet = String(long.prefix(PluginSpecProcession.creatorTabTitleSnippetLimit))
        #expect(title == "Create plugin - \(snippet)...")
    }

    @Test func namedSiteAccessAsksForDocsURLWhenSearchFindsNothing() {
        var session = PluginSpecSession()
        _ = PluginSpecProcession.advance(session: &session, utterance: "Summaries of tech news")
        let reviewing = PluginSpecProcession.advance(
            session: &session,
            utterance: "Google News, and also the Wall Street Journal."
        )
        #expect(session.ask == .slot(.access))
        #expect(reviewing.reply == PluginAccessAskPolicy.reviewingQuestion)

        session.draft.needsHumanDocsURL = true
        session.ask = .docsURL
        #expect(PluginSpecProcession.question(for: .docsURL, session: session)
            == PluginAccessAskPolicy.docsURLFindQuestion)

        let invalid = PluginSpecProcession.advance(session: &session, utterance: "I don't know")
        #expect(session.ask == .docsURL)
        #expect(invalid.reply.contains("web address"))

        let withURL = PluginSpecProcession.advance(
            session: &session,
            utterance: "https://developers.google.com/news/api"
        )
        #expect(session.draft.documentationURL == "https://developers.google.com/news/api")
        #expect(session.ask == .slot(.access))
        #expect(withURL.reply == PluginAccessAskPolicy.reviewingQuestion)
    }

    @Test func accessAskIsFormulatedFromDocsSummaryAndLink() {
        let connect = PluginConnectBinding(klass: .messagingInbox, detail: "Telegram")
        #expect(PluginAccessAskPolicy.documentationURL(from: connect) == nil)
        #expect(PluginAccessAskPolicy.question(connect: connect, discovery: nil)
            == PluginAccessAskPolicy.reviewingQuestion)

        let discovery = ConnectorAuthDiscovery(
            authScheme: .botToken,
            secrets: [],
            setupHint: "Telegram bots use a token from BotFather when calling the HTTP API.",
            crawlSummary: "Create a bot with BotFather and copy the token."
        )
        let question = PluginAccessAskPolicy.question(
            connect: connect,
            discovery: discovery,
            documentationURL: "https://docs.example.com/bots/auth"
        )
        #expect(question.contains("BotFather"))
        #expect(question.contains("https://docs.example.com/bots/auth"))
        #expect(question.contains("[Read the setup docs]"))
        #expect(question.contains(PluginAccessAskPolicy.genericQuestion) == false)
    }

    @Test func accessAskPrefersACallTokenOverOAuthClientCredentials() throws {
        let oauthInstall = ConnectorAuthDiscovery(
            authScheme: .oauth,
            secrets: [
                try PluginSecretField(id: "client_id", label: "Client ID", kind: .apiKey),
                try PluginSecretField(id: "client_secret", label: "Client Secret", kind: .password),
            ],
            setupHint: "Create an app and copy the client id and client secret.",
            crawlSummary: """
            Apps also get a bot token after install. Send that bot token in the \
            Authorization header on each HTTP API call. Client id and secret are \
            only used to install the app.
            """
        )
        let preferred = oauthInstall.preferringCallCredential()
        #expect(preferred.authScheme == .botToken)
        #expect(preferred.secrets.map(\.id) == ["bot_token"])
        let question = PluginAccessAskPolicy.question(
            connect: PluginConnectBinding(klass: .messagingInbox, detail: "a chat API"),
            discovery: oauthInstall
        )
        #expect(question.lowercased().contains("bot token"))
        #expect(question.lowercased().contains("client id") == false)

        let apiKeyNotes = ConnectorAuthDiscovery(
            authScheme: .oauth,
            secrets: [
                try PluginSecretField(id: "client_id", label: "Client ID", kind: .apiKey),
                try PluginSecretField(id: "client_secret", label: "Client Secret", kind: .password),
            ],
            crawlSummary: "Call the REST API with an API key in the X-Api-Key header."
        )
        #expect(apiKeyNotes.preferringCallCredential().authScheme == .apiKey)
        #expect(apiKeyNotes.preferringCallCredential().secrets.map(\.id) == ["api_key"])

        let oauthOnly = ConnectorAuthDiscovery(
            authScheme: .oauth,
            secrets: [
                try PluginSecretField(id: "client_id", label: "Client ID", kind: .apiKey),
                try PluginSecretField(id: "client_secret", label: "Client Secret", kind: .password),
            ],
            crawlSummary: "The API is OAuth only. Exchange the client id and secret for access."
        )
        #expect(oauthOnly.preferringCallCredential().authScheme == .botToken)
        #expect(oauthOnly.preferringCallCredential().authScheme.isSupportedInWizard)
        #expect(oauthOnly.preferringCallCredential().secrets.map(\.id) == ["api_token"])
        #expect(oauthOnly.preferringCallCredential().secrets.map(\.id).contains("client_id") == false)
    }

    @Test func vendorDocsLocatorPrefersAuthHitsAndIgnoresSearchHosts() throws {
        let worker = """
        {"ok":true,"query":"Example API","hits":[\
        {"title":"Pricing","url":"https://example.com/pricing","snippet":"Plans and billing."},\
        {"title":"Auth tokens","url":"https://docs.example.com/auth/tokens","snippet":"Create an API token."},\
        {"title":"Search","url":"https://duckduckgo.com/l/?q=x","snippet":"ignored"}\
        ],"diagnostics":[]}
        """
        let outcome = try ToolExecutionOutcome.completed(
            output: ToolExecutionOutcome.Output(format: .json, value: worker)
        ).encodedJSON()
        #expect(
            VendorDocsLocator.preferredDocumentationURL(fromSearchToolText: outcome)
                == "https://docs.example.com/auth/tokens"
        )
        #expect(
            VendorDocsLocator.searchQuery(sourceName: "Slack")
                .contains("Slack")
        )
        #expect(
            VendorDocsLocator.searchQuery(
                sourceName: "connect to slack and send receive messages"
            )
            == "slack API authentication documentation"
        )
        #expect(
            VendorDocsLocator.inboxAPISearchQuery(sourceName: "Slack")
            == "Slack API list conversations channels threads documentation"
        )
        #expect(VendorDocsLocator.sanitizedHTTPURL("https://html.duckduckgo.com/html/") == nil)
        let workerSlack = """
        {"ok":true,"query":"slack API authentication documentation","hits":[\
        {"title":"Authentication overview | Slack Developer Docs","url":"https://docs.slack.dev/authentication/","snippet":"OAuth 2.0, verifying requests, or setting up Sign in with Slack."},\
        {"title":"Slack authentication | Documentation","url":"https://docs.weweb.io/database-and-apis/auth/providers/slack.html","snippet":"Slack authentication lets your users sign in with their Slack account. Copy Client ID and Client Secret. Success Page in WeWeb."},\
        {"title":"Tokens","url":"https://docs.slack.dev/authentication/tokens","snippet":"Slack apps authenticate with a bot token sent on each HTTP API call."}\
        ],"diagnostics":[]}
        """
        let slackOutcome = try ToolExecutionOutcome.completed(
            output: ToolExecutionOutcome.Output(format: .json, value: workerSlack)
        ).encodedJSON()
        #expect(
            VendorDocsLocator.preferredDocumentationURL(fromSearchToolText: slackOutcome)
                == "https://docs.slack.dev/authentication/tokens"
        )
        let crawlJSON = """
        {"ok":true,"start_url":"https://api.slack.com/authentication/tokens","pages":[\
        {"url":"https://docs.slack.dev/404?from=/authentication/tokens","depth":0,"status_code":404,"title":"Not found","text":"missing","links_found":[]},\
        {"url":"https://docs.slack.dev/authentication/tokens","depth":1,"status_code":200,"title":"Tokens","text":"Slack apps use a bot token.","links_found":[]}\
        ],"stop_reason":"completed","requests_made":2,"bytes_read":10,"truncated":false,"diagnostics":[]}
        """
        let crawlOutcome = try ToolExecutionOutcome.completed(
            output: ToolExecutionOutcome.Output(format: .json, value: crawlJSON)
        ).encodedJSON()
        let summary = VendorDocsLocator.crawlSummary(fromToolText: crawlOutcome)
        #expect(summary?.contains("bot token") == true)
        #expect(summary?.contains("Not found") == false)
        #expect(summary?.contains("Welcome to WeWeb") == false)
        let wewebCrawl = """
        {"ok":true,"start_url":"https://docs.weweb.io/database-and-apis/auth/providers/slack.html","pages":[\
        {"url":"https://docs.weweb.io/database-and-apis/auth/providers/slack.html","depth":0,"status_code":200,"title":"Slack authentication","text":"Copy Client ID.","links_found":1},\
        {"url":"https://docs.weweb.io/","depth":1,"status_code":200,"title":"Welcome to WeWeb","text":"Welcome to WeWeb homepage padding.","links_found":0}\
        ],"stop_reason":"max_pages","requests_made":2,"bytes_read":10,"truncated":false,"diagnostics":[]}
        """
        let wewebOutcome = try ToolExecutionOutcome.completed(
            output: ToolExecutionOutcome.Output(format: .json, value: wewebCrawl)
        ).encodedJSON()
        let wewebSummary = VendorDocsLocator.crawlSummary(fromToolText: wewebOutcome)
        #expect(wewebSummary?.contains("Client ID") == true)
        #expect(wewebSummary?.contains("Welcome to WeWeb") == false)
    }

    @Test func failedDocsReviewAsksForAURLInsteadOfContinuing() {
        var session = PluginSpecSession()
        session.draft.connect = PluginConnectBinding(klass: .namedSite, detail: "Some API")
        session.draft.claimedOutcome = "Fetch items"
        session.draft.documentationURL = "https://example.invalid/docs"
        session.draft.needsHumanDocsURL = true
        session.draft.documentationURLFromHuman = true
        session.ask = .docsURL
        #expect(PluginSpecProcession.question(for: .docsURL, session: session)
            == PluginAccessAskPolicy.docsURLQuestion(
                triedURL: "https://example.invalid/docs",
                fromHuman: true
            ))
        #expect(PluginSpecProcession.nextAsk(session.draft) == .docsURL)
    }

    @Test func askingDerrickToSearchRetriesDocsLookup() {
        var session = PluginSpecSession()
        session.draft.connect = PluginConnectBinding(
            klass: .messagingInbox,
            detail: "connect to slack and send receive messages"
        )
        session.draft.claimedOutcome = "connect to slack and send receive messages"
        session.draft.needsHumanDocsURL = true
        session.ask = .docsURL
        let turn = PluginSpecProcession.advance(
            session: &session,
            utterance: "can you search for it"
        )
        #expect(session.draft.needsHumanDocsURL == false)
        #expect(session.draft.documentationURL == nil)
        #expect(session.ask == .slot(.access))
        #expect(turn.reply == PluginAccessAskPolicy.reviewingQuestion)
        #expect(PluginAccessAskPolicy.isDocsSearchRequest("can you search for it"))
        #expect(PluginAccessAskPolicy.isDocsSearchRequest("I don't know") == false)
    }

    @Test func docsURLAskNamesASearchHitWithoutBlamingTheUser() {
        #expect(
            PluginAccessAskPolicy.docsURLQuestion()
                == PluginAccessAskPolicy.docsURLFindQuestion
        )
        let searchMiss = PluginAccessAskPolicy.docsURLQuestion(
            triedURL: "https://api.slack.com/authentication/basics",
            fromHuman: false
        )
        #expect(searchMiss.contains("https://api.slack.com/authentication/basics"))
        #expect(searchMiss.contains("looked at"))
        #expect(searchMiss.contains("Paste a different page") == false)
        let humanMiss = PluginAccessAskPolicy.docsURLQuestion(
            triedURL: "https://api.slack.com/authentication/basics",
            fromHuman: true
        )
        #expect(humanMiss.contains("could not use"))
        #expect(humanMiss.contains("https://api.slack.com/authentication/basics"))
        #expect(
            PluginAccessAskPolicy.docsURLQuestion(failure: .webToolsNotReady)
                == PluginAccessAskPolicy.webToolsNotReadyQuestion
        )
        #expect(
            WorkerImageFailureDisplay.isWorkerImageIssue(
                "The worker image derrick-worker:go-v1 does not match the version shipped with Derrick."
            )
        )
        #expect(
            WorkerImageFailureDisplay.userFacing(
                from: "The worker image derrick-worker:go-v1 does not match the version shipped with Derrick. Rebuild or reinstall product images."
            )
            == WorkerImageFailureDisplay.runtimeNotReady
        )
        #expect(
            WorkerImageFailureDisplay.isWorkerImageIssue(
                "Derrick could not prepare its web tools. Make sure Docker Desktop is running."
            )
        )
        #expect(
            WorkerImageFailureDisplay.isWorkerImageIssue(
                "XPC validation: docker flag is not allowed: image inspect"
            )
        )
        let invented = ConnectorAuthDiscovery(
            authScheme: .apiKey,
            secrets: [],
            setupHint: "Slack apps authenticate with a bot token."
        )
        #expect(PluginAccessAskPolicy.hasUsableDocs(invented))
        #expect(
            PluginAccessAskPolicy.docsReviewSucceeded(
                failure: .searchEmpty,
                auth: invented
            ) == false
        )
        #expect(
            PluginAccessAskPolicy.docsReviewSucceeded(
                failure: nil,
                auth: invented
            )
        )
    }
}

@Suite struct PluginPresentPolicyTests {
    @Test func listReturnBindsGeneratedView() {
        var spec = PluginSpecDraft(returnClass: .list)
        #expect(PluginPresentPolicy.bind(spec: spec) == .decided(.generatedView))
        spec.returnClass = .file
        #expect(PluginPresentPolicy.bind(spec: spec) == .decided(.file))
        spec.returnClass = .image
        #expect(PluginPresentPolicy.bind(spec: spec) == .decided(.image))
        spec.returnClass = .brief
        #expect(PluginPresentPolicy.bind(spec: spec) == .decided(.conversation))
        spec.connect = PluginConnectBinding(klass: .messagingInbox, detail: "Slack")
        #expect(PluginPresentPolicy.bind(spec: spec) == .decided(.thread))
    }

    @Test func wrongnessOverridesConversationToGeneratedView() {
        let binding = PluginPresentPolicy.applyWrongness(
            "Not a wall of markdown; I need to skim many stories",
            current: .conversation
        )
        #expect(binding == .decided(.generatedView))
    }

    @Test func wrongnessOverridesGeneratedViewToConversation() {
        let binding = PluginPresentPolicy.applyWrongness(
            "Just tell me in the chat",
            current: .generatedView
        )
        #expect(binding == .decided(.conversation))
    }

    @Test func wrongnessCanForceFile() {
        #expect(
            PluginPresentPolicy.applyWrongness("I need the actual document", current: .conversation)
                == .decided(.file)
        )
    }

    @Test func makeFromSpecDraftRequiresPresent() {
        let empty = PluginSpecDraft(claimedOutcome: "do it")
        #expect(throws: PluginCreatorSpecError.notBuildable) {
            try PluginFactoryCreateInput.makeFromSpecDraft(empty)
        }
    }

    @Test func makeFromSpecDraftSucceedsWhenComplete() throws {
        let spec = PluginSpecDraft(
            claimedOutcome: "Summarize my notes",
            connect: PluginConnectBinding(klass: .localFiles, detail: "files on this Mac"),
            access: .reachable,
            work: .summarize,
            returnClass: .brief,
            triggers: [.chat],
            present: .conversation,
            presentSource: .inferred,
            wrongness: "not an empty reply"
        )
        let input = try PluginFactoryCreateInput.makeFromSpecDraft(spec)
        #expect(input.pluginType == .custom)
        #expect(input.pluginID != nil)
    }

    @Test func makeFromSpecDraftKeepsReservedPluginIDAndCallCredential() throws {
        let spec = PluginSpecDraft(
            claimedOutcome: "connect to slack and send and receive messages",
            connect: PluginConnectBinding(klass: .messagingInbox, detail: "Slack"),
            access: .reachable,
            work: .send,
            returnClass: .message,
            triggers: [.chat, .mention, .messaging],
            present: .conversation,
            presentSource: .inferred,
            wrongness: "must not post without asking"
        )
        let oauthOnly = ConnectorAuthDiscovery(
            authScheme: .oauth,
            secrets: [
                try PluginSecretField(id: "client_id", label: "Client ID", kind: .apiKey),
                try PluginSecretField(id: "client_secret", label: "Client Secret", kind: .password),
            ],
            setupHint: "Create an app and copy the client id and client secret.",
            crawlSummary: "The API is OAuth only."
        )
        let input = try PluginFactoryCreateInput.makeFromSpecDraft(
            spec,
            auth: oauthOnly,
            pluginID: "slack-connector-1"
        )
        #expect(input.pluginID == "slack-connector-1")
        #expect(input.auth?.authScheme.isSupportedInWizard == true)
        #expect(input.auth?.secrets.map(\.id) == ["api_token"])
        #expect(
            PluginAccessAskPolicy.credentialFormPrompt(discovery: oauthOnly)
                .lowercased().contains("client id") == false
        )
    }
}
