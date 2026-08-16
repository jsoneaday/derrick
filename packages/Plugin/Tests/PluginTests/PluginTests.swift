import Testing
import Foundation
@testable import Plugin

@Test func unknownVerbFailsClosed() throws {
    let data = Data(#"[{"verb":"call_tool","url":"https://evil.example"}]"#.utf8)
    #expect(throws: PluginEnvelopeError.unknownVerb("call_tool")) {
        _ = try PluginEnvelopeList.decode(data)
    }
}

@Test func nilErrorIsNotAFailure() {
    #expect(!PluginFailureSemantics.isFailure(nil as String?))
    #expect(!PluginFailureSemantics.isFailure(""))
    #expect(!PluginFailureSemantics.isFailure("  "))
    #expect(!PluginFailureSemantics.isFailure(PluginJSON.null))
    #expect(!PluginFailureSemantics.isFailure(PluginJSON?.none))
    #expect(PluginFailureSemantics.isFailure("timeout"))
    #expect(HostHTTPResponse(requestID: "r", status: 200, error: nil).succeeded)
    #expect(!HostHTTPResponse(requestID: "r", status: 0, error: "ssrf").succeeded)
    #expect(HostHTTPResponse(requestID: "r", status: 200, body: "<html>").body == "<html>")
}

@Test func jsonWireTurnsOptionalNoneIntoJSONNull() throws {
    let raw: [String: Any] = ["status": 200, "error": Optional<String>.none as Any]
    let data = try JSONWire.data(jsonObject: raw)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?["status"] as? Int == 200)
    #expect(object?["error"] is NSNull)
}

@Test func invalidJSONHasReadableError() {
    #expect(throws: PluginEnvelopeError.invalidJSON("not-json")) {
        _ = try PluginEnvelopeList.decode(Data("not-json".utf8))
    }
}

@Test func handleMustReturnJSONArray() throws {
    #expect(throws: PluginEnvelopeError.notAnArray) {
        _ = try PluginEnvelopeList.decode(Data(#"{"verb":"log","message":"x"}"#.utf8))
    }
    #expect(throws: PluginEnvelopeError.notAnArray) {
        _ = try PluginEnvelopeList.decode(Data(#""plain text""#.utf8))
    }
    let one = try PluginEnvelopeList.decode(Data(#"[{"verb":"result.emit","text":"ok"}]"#.utf8))
    #expect(one.count == 1)
    #expect(one[0].verb == .resultEmit)
}

@Test func hopEventRoundTripsParams() throws {
    let event = PluginHopEvent(
        kind: .manual,
        params: ["topic": .string("tech"), "limit": .number(5)]
    )
    let data = try JSONWire.encode(PluginHostInvoke(seq: 0, event: event))
    let decoded = try JSONDecoder().decode(PluginHostInvoke.self, from: data)
    #expect(decoded.event.kind == .manual)
    #expect(decoded.event.params?["topic"]?.stringValue == "tech")
}

@Test func pluginPrefixMatchesExactlyOne() {
    #expect(PluginPrefix.parse("/daily-news")?.handle == "daily-news")
    #expect(PluginPrefix.parse("/daily-news tech")?.remainder == "tech")
    #expect(PluginPrefix.parse("hello") == nil)
    #expect(PluginPrefix.parse("//not-a-plugin") == nil)
    #expect(PluginPrefix.uniqueMatch(handle: "daily", pluginIDs: ["daily-news"]) == "daily-news")
    #expect(PluginPrefix.uniqueMatch(handle: "daily", pluginIDs: ["daily-news", "daily-mail"]) == nil)
    #expect(PluginPrefix.uniqueMatch(handle: "daily-news", pluginIDs: ["daily-news"]) == "daily-news")
    #expect(PluginPrefix.typingHandle("/") == "")
    #expect(PluginPrefix.typingHandle("/daily") == "daily")
    #expect(PluginPrefix.typingHandle("/create-plugin") == "create-plugin")
    #expect(PluginPrefix.typingHandle("/create") == "create")
    #expect(PluginPrefix.matches(handle: "create", pluginIDs: ["create-plugin", "daily-news"]) == ["create-plugin"])
    #expect(PluginPrefix.typingHandle("/daily-news more") == nil)
    #expect(PluginPrefix.typingHandle("hello") == nil)
    #expect(PluginPrefix.typingHandle("//nope") == nil)
    #expect(PluginPrefix.matches(handle: "", pluginIDs: ["zeta", "alpha"]) == ["alpha", "zeta"])
    #expect(PluginPrefix.matches(handle: "daily", pluginIDs: ["daily-news", "daily-mail", "weather"]) == ["daily-mail", "daily-news"])
    #expect(PluginPrefix.matches(handle: "news", pluginIDs: ["daily-news-summary", "weather"]) == ["daily-news-summary"])
}

@Test func factoryInvokeParamsPreferFixturesThenHandleKeys() {
    let fixtures = #"[{"kind":"test","params":{"topic":"science","max":3}}]"#
    let handle = """
    interface PluginParams {
      topic?: string;
      max?: number;
      query?: string;
    }
    export function handle(event: HandleEvent<PluginParams>): HandleResult { return []; }
    """
    let fromFixtures = FactoryInvokeParams.resolve(
        fixturesJSON: fixtures,
        handle: handle,
        goal: "topic and max articles"
    )
    #expect(fromFixtures["topic"]?.stringValue == "science")
    if case .number(let max) = fromFixtures["max"] {
        #expect(max == 3)
    } else {
        Issue.record("expected max from fixtures")
    }

    let inferred = FactoryInvokeParams.resolve(
        fixturesJSON: FactoryPackageDraft.defaultFixturesJSON,
        handle: handle,
        goal: #"edit daily news for topic "climate" and max"#
    )
    #expect(inferred.isEmpty)
    #expect(Set(FactoryInvokeParams.referencedKeys(in: handle)) == ["topic", "max", "query"])
    #expect(FactoryInvokeParams.isPlaceholder(["sample": .bool(true)]))
    #expect(FactoryInvokeParams.testHeading(pluginID: "daily-news", params: fromFixtures)
        == "Testing new plugin daily-news (max=3, topic=science)…")

    let chat = FactoryInvokeParams.chatParams(remainder: "technology 4")
    #expect(chat["text"]?.stringValue == "technology 4")
    #expect(chat["topic"]?.stringValue == "technology")
    if case .number(let max) = chat["max"] {
        #expect(max == 4)
    } else {
        Issue.record("expected chat max")
    }
    #expect(FactoryInvokeParams.chatParams(remainder: "").isEmpty)
}

@Test func factoryInvokeParamsTypesCountsAndLists() {
    let handle = """
    interface PluginParams {
      topics?: string[];
      sources?: string[];
      maxResultCount?: number;
      maxResults?: number;
    }
    export function handle(event: HandleEvent<PluginParams>): HandleResult { return []; }
    """
    let inferred = FactoryInvokeParams.inferred(handle: handle, goal: "news sources topics and max result count")
    if case .number(let max) = inferred["maxResultCount"] {
        #expect(max == 5)
    } else {
        Issue.record("maxResultCount should be a number")
    }
    if case .number(let max) = inferred["maxResults"] {
        #expect(max == 5)
    } else {
        Issue.record("maxResults should be a number")
    }
    if case .array(let topics) = inferred["topics"], case .string(let first) = topics.first {
        #expect(first == "technology")
    } else {
        Issue.record("topics should be a string list")
    }
    if case .array(let sources) = inferred["sources"], case .string(let first) = sources.first {
        #expect(first == "technology")
    } else {
        Issue.record("sources should be a string list")
    }

    let garbage = FactoryInvokeParams.normalize(
        [
            "maxResultCount": .string("technology"),
            "maxResults": .string("technology"),
            "sources": .string("technology"),
            "topics": .string("technology"),
        ],
        handle: handle,
        goal: "news"
    )
    if case .number = garbage["maxResultCount"] { } else {
        Issue.record("garbage maxResultCount must be coerced to a number")
    }
    if case .array = garbage["topics"] { } else {
        Issue.record("garbage topics must become a list")
    }

    let schema = FactoryInvokeParams.parseSchema(#"{"maxResultCount":"number","topics":"string[]"}"#)
    #expect(schema["maxResultCount"] == .number)
    #expect(schema["topics"] == .stringList)
}

@Test func pluginTypeSafetyBansAnyAndAssertions() {
    #expect(PluginTypeSafety.findings(in: "const x: any = 1;").isEmpty == false)
    #expect(PluginTypeSafety.findings(in: "const x = value as string;").isEmpty == false)
    #expect(PluginTypeSafety.findings(in: "const x = value as unknown as number;").isEmpty == false)
    #expect(PluginTypeSafety.findings(in: "// @ts-ignore\nconst x = 1;").isEmpty == false)
    #expect(PluginTypeSafety.findings(in: "const x: unknown = body;\nif (typeof x === \"string\") { return x; }").isEmpty)
    #expect(PluginTypeSafety.findings(in: "export function handle(event: HandleEvent<PluginParams>): HandleResult { return []; }").isEmpty)
}

@Test func pluginParamsContractRejectsUnknownAndAny() {
    #expect(!PluginParamsContract.validate("export function handle(event: HandleEvent): HandleResult { return []; }").isEmpty)
    let unknown = """
    interface PluginParams { topic?: unknown; }
    export function handle(event: HandleEvent<PluginParams>): HandleResult { return []; }
    """
    #expect(PluginParamsContract.validate(unknown).contains { $0.contains("unknown") || $0.contains("base type") })
    let anyBag = """
    interface PluginParams { extra?: Record<string, any>; }
    export function handle(event: HandleEvent<PluginParams>): HandleResult { return []; }
    """
    #expect(!PluginParamsContract.validate(anyBag).isEmpty)
    let empty = """
    interface PluginParams {}
    export function handle(event: HandleEvent<PluginParams>): HandleResult { return []; }
    """
    #expect(PluginParamsContract.validate(empty).isEmpty)
    let index = """
    interface PluginParams { [key: string]: string; }
    export function handle(event: HandleEvent<PluginParams>): HandleResult { return []; }
    """
    #expect(PluginParamsContract.validate(index).contains { $0.contains("index signature") })
    let recordAlias = """
    type PluginParams = Record<string, string>;
    export function handle(event: HandleEvent<PluginParams>): HandleResult { return []; }
    """
    #expect(!PluginParamsContract.validate(recordAlias).isEmpty)
    let ok = """
    interface PluginParams { topic?: string; max?: number; sources?: string[]; }
    export function handle(event: HandleEvent<PluginParams>): HandleResult { return []; }
    """
    #expect(PluginParamsContract.validate(ok).isEmpty)
    #expect(PluginParamsContract.declaredKinds(ok)["max"] == .number)
    #expect(PluginParamsContract.declaredKinds(ok)["sources"] == .stringList)
}

@Test func factoryAttemptLogIncludesHandleAndFindings() {
    let text = FactoryAttemptLog.describe(
        tool: "factory.write_package",
        arguments: [
            "plugin_id": "daily-news-summary",
            "handle": "export function handle() { return []; }",
        ],
        result: #"{"ok":false,"stage":"written","static_findings":["Guest fetch() is banned"],"next":"factory.write_package"}"#
    )
    #expect(text.contains("[factory] factory.write_package ok=false"))
    #expect(text.contains("Guest fetch() is banned"))
    #expect(text.contains("handle begin"))
    #expect(text.contains("export function handle()"))
}

@Test func factoryExistingPluginMatchPrefersInstalledIdOnEdit() {
    let installed = ["daily-news", "daily-news-summary"]
    #expect(
        FactoryExistingPlugin.decide(
            goal: "can we edit the existing daily news plugin so that it can receive a topic?",
            installedIDs: installed
        ) == .ambiguous(["daily-news", "daily-news-summary"])
    )
    #expect(
        FactoryExistingPlugin.match(
            goal: "edit daily-news-summary to add a limit",
            installedIDs: installed
        ) == "daily-news-summary"
    )
    #expect(
        FactoryExistingPlugin.match(
            goal: "edit the summary plugin",
            installedIDs: installed
        ) == "daily-news-summary"
    )
    #expect(
        FactoryExistingPlugin.match(
            goal: "build a daily news plugin",
            installedIDs: installed
        ) == nil
    )
    #expect(
        FactoryExistingPlugin.decide(
            goal: "update the daily news plugin so that it accepts parameters",
            installedIDs: ["daily-news-summary"]
        ) == .reuse("daily-news-summary")
    )
    #expect(
        FactoryExistingPlugin.decide(
            goal: "update the plugin with organizations, topics, and a max count",
            installedIDs: ["daily-news", "daily-news-summary"]
        ) == .ambiguous(["daily-news", "daily-news-summary"])
    )
    #expect(FactoryExistingPlugin.nameFits(pluginID: "daily-news-summary", goal: "daily news"))
    #expect(FactoryExistingPlugin.nameFits(pluginID: "daily-news", goal: "daily news"))
    #expect(
        FactoryExistingPlugin.decide(
            goal: "create a weather plugin",
            installedIDs: ["daily-news-summary"]
        ) == .create
    )
    #expect(
        FactoryExistingPlugin.decide(
            goal: "edit the weather plugin to add a zip code",
            installedIDs: ["daily-news-summary", "weather"]
        ) == .reuse("weather")
    )
    #expect(
        FactoryExistingPlugin.decide(
            goal: "Create a complementary plugin.",
            installedIDs: ["create-plugin"]
        ) == .create
    )
    #expect(PluginReleaseVersion.next(after: "1.0.0") == "1.0.1")
    #expect(PluginReleaseVersion.assign(requested: "1.0.0", existing: ["1.0.0"]) == "1.0.1")
    #expect(PluginReleaseVersion.assign(requested: "2.0.0", existing: ["1.0.0"]) == "2.0.0")
    #expect(PluginReleaseVersion.assign(requested: "1.0.0", existing: []) == "1.0.0")
}

@Test func hookGrantsDecodeNamesAndObjects() {
    let fromNames = PluginHookGrant.decodeList(#"["open_factory_session"]"#)
    #expect(fromNames.map(\.hook) == [.openFactorySession])
    #expect(fromNames.first?.event == PluginHookGrant.pluginInvokeEvent)
    #expect(fromNames.first?.phase == .before)
    let encoded = PluginHookGrant.encodeList([PluginHookGrant(hook: .openFactorySession)])
    let fromObjects = PluginHookGrant.decodeList(encoded)
    #expect(fromObjects == [PluginHookGrant(hook: .openFactorySession)])
    #expect(PluginHookGrant.decodeList("[]").isEmpty)
    #expect(PluginHookGrant.decodeList("not-json").isEmpty)
}

@Test func createPluginSampleIsSkillOnly() {
    #expect(CreatePluginSample.pluginID == "create-plugin")
    #expect(CreatePluginSample.skillMarkdown.contains("factory.build"))
    #expect(CreatePluginSample.skillMarkdown.contains("derrick.ts"))
    #expect(!CreatePluginSample.manifestJSON.contains("entrypoint"))
    let grants = PluginHookGrant.decodeList(CreatePluginSample.hooksJSON)
    #expect(grants.map(\.hook) == [.openFactorySession])
    let hash = CreatePluginSample.contentHash()
    #expect(hash.rawValue.count == 64)
}

@Test func dailyNewsSampleIsAValidDraft() throws {
    let draft = DailyNewsSample.draft()
    #expect(draft.pluginID == "daily-news")
    #expect(try draft.pluginJSON().contains("daily-news"))
    #expect(draft.handle.contains("export function handle"))
    #expect(draft.handle.contains("netFetch"))
    #expect(draft.handle.contains("headlines"))
    #expect(draft.handle.contains("foxnews.com"))
    #expect(draft.handle.contains("interface PluginParams"))
    #expect(draft.handle.contains("HandleEvent<PluginParams>"))
    #expect(PluginParamsContract.validate(draft.handle).isEmpty)
    #expect(draft.fixturesJSON.contains("technology"))
    #expect(!draft.volumeEnabled)
    let hash = try draft.contentHash()
    #expect(hash.rawValue.count == 64)
}

@Test func factoryDraftHashesStableFiles() throws {
    var draft = FactoryPackageDraft(
        goal: "headlines",
        pluginID: "daily-news",
        version: "1.0.0",
        description: "Headlines from one host.",
        handle: "import { netFetch, type HandleEvent, type HandleResult } from \"derrick\";\nexport function handle(event: HandleEvent): HandleResult { return netFetch({ url: \"https://www.bbc.com\" }); }\n"
    )
    let hash = try draft.contentHash()
    #expect(hash.rawValue.count == 64)
    #expect(try draft.pluginJSON().contains("daily-news"))
    let again = try draft.contentHash()
    #expect(again == hash)
    draft.handle += " "
    #expect(try draft.contentHash() != hash)
}

@Test func envelopeSchemaRequiresArrayAndVerb() {
    #expect(PluginEnvelopeSchema.jsonSchema.contains("\"type\": \"array\""))
    #expect(PluginEnvelopeSchema.verbCases.contains("http.request"))
    #expect(PluginEnvelopeSchema.verbCases.contains("result.emit"))
    #expect(DerrickGuestTypeScript.derrickModule.contains("export type HandleResult = Envelope[]"))
    #expect(DerrickGuestTypeScript.derrickModule.contains("export function httpBody"))
    #expect(DerrickGuestTypeScript.derrickModule.contains("export function stripMarkup"))
    #expect(DerrickGuestTypeScript.derrickModule.contains("export type PluginParamValue"))
    #expect(DerrickGuestTypeScript.derrickModule.contains("export interface HandleEvent<P extends ParamFields<P> = Record<string, never>>"))
    #expect(DerrickGuestTypeScript.derrickModule.contains("auth_ref?: string | null"))
    #expect(!DerrickGuestTypeScript.derrickModule.contains("[key: string]"))
    #expect(!DerrickGuestTypeScript.derrickModule.contains("params?: Record<string, unknown>"))
    #expect(DerrickGuestTypeScript.handleCheckTS.contains("FieldValues"))
    #expect(DerrickGuestTypeScript.handleCheckTS.contains("_NoIndex"))
    #expect(PluginMarkup.strip("<![CDATA[Major incidents across UK]]>") == "Major incidents across UK")
    #expect(PluginMarkup.strip("<title><![CDATA[Hello]]></title>") == "Hello")
    #expect(PluginMarkup.naiveTagStripFinding("value.replace(/<[^>]*>/g, '')") != nil)
    #expect(PluginMarkup.naiveTagStripFinding("stripMarkup(block)") == nil)
    #expect(DerrickGuestTypeScript.verbUnion.contains("\"http.request\""))
    #expect(PluginInvokePresentation.isEmptyResult("No matching daily news items were found."))
    #expect(PluginInvokePresentation.isEmptyResult("No Reuters news items were available today."))
    #expect(!PluginInvokePresentation.isEmptyResult("1. A real headline from the BBC"))
    #expect(DerrickGuestTypeScript.derrickModule.contains("export function headlines"))
    #expect(DerrickGuestTypeScript.derrickModule.contains("export function httpFailed"))
    #expect(DerrickGuestTypeScript.runnerSource.contains("script.ts"))
    #expect(DerrickGuestTypeScript.runnerSource.contains("invoke.event"))
    for verb in PluginEnvelopeSchema.verbCases {
        #expect(DerrickGuestTypeScript.derrickModule.contains("\"\(verb)\""))
    }
    #expect(
        PluginMarkup.headlines(
            #"<h2 data-testid="card-headline">Rescuers search for survivors of quake</h2><h2>Morocco detains dozens of migrants</h2>"#
        ).first == "Rescuers search for survivors of quake"
    )
    #expect(
        PluginMarkup.headlines(
            #"<rss><item><title><![CDATA[Major incidents across UK]]></title></item></rss>"#
        ) == ["Major incidents across UK"]
    )
    #expect(PluginEnvelopeSchema.ragSection.contains("TypeScript"))
    #expect(PluginEnvelopeSchema.ragSection.contains("handle() return"))
    #expect(PluginEnvelopeSchema.ragSection.contains("interface PluginParams"))
    #expect(!PluginEnvelopeSchema.ragSection.contains("[key: string]: unknown"))
    #expect(!PluginEnvelopeSchema.ragSection.contains("export function stripMarkup"))
    #expect(!PluginEnvelopeSchema.ragSection.contains("\"$schema\""))
    #expect(!DerrickGuestTypeScript.tsconfigJSON.contains("baseUrl"))
    #expect(DerrickGuestTypeScript.tsconfigJSON.contains("\"noImplicitAny\": true"))
    #expect(DerrickGuestTypeScript.tsconfigJSON.contains("\"useUnknownInCatchVariables\": true"))
    #expect(DerrickGuestTypeScript.tsconfigJSON.contains("\"types\": []"))
    #expect(!DerrickGuestTypeScript.handleCheckTS.contains("./script.ts"))
}

@Test func nestedResultObjectFlattensIntoPayload() throws {
    let data = Data(#"[{"type":"result.emit","result":{"title":"Apple","summary":"iPhone"}}]"#.utf8)
    let list = try PluginEnvelopeList.decode(data)
    #expect(list[0].verb == .resultEmit)
    #expect(list[0].payload["title"]?.stringValue == "Apple")
    #expect(list[0].payload["summary"]?.stringValue == "iPhone")
}

@Test func missingVerbInfersResultFromSummary() throws {
    let data = Data(#"[{"title":"Apple","summary":"iPhone on apple.com"}]"#.utf8)
    let list = try PluginEnvelopeList.decode(data)
    #expect(list[0].verb == .resultEmit)
    #expect(list[0].payload["title"]?.stringValue == "Apple")
    #expect(list[0].payload["summary"]?.stringValue == "iPhone on apple.com")
}

@Test func missingVerbInfersHTTPFromURL() throws {
    let data = Data(#"[{"url":"https://www.apple.com","method":"GET"}]"#.utf8)
    let list = try PluginEnvelopeList.decode(data)
    #expect(list[0].verb == .httpRequest)
    #expect(list[0].payload["url"]?.stringValue == "https://www.apple.com")
}

@Test func nestedResultWithoutTypeInfersResultEmit() throws {
    let data = Data(#"[{"result":{"title":"Apple","summary":"Storefront"}}]"#.utf8)
    let list = try PluginEnvelopeList.decode(data)
    #expect(list[0].verb == .resultEmit)
    #expect(list[0].payload["summary"]?.stringValue == "Storefront")
}

@Test func emptyObjectStillFailsClosed() throws {
    let data = Data(#"[{}]"#.utf8)
    #expect(throws: PluginEnvelopeError.unknownVerb("(missing)")) {
        _ = try PluginEnvelopeList.decode(data)
    }
}

@Test func informalTypeResultDecodesAsResultEmit() throws {
    let data = Data(#"[{"type":"result","title":"Apple","text":"iPhone"}]"#.utf8)
    let list = try PluginEnvelopeList.decode(data)
    #expect(list.count == 1)
    #expect(list[0].verb == .resultEmit)
    #expect(list[0].payload["title"]?.stringValue == "Apple")
    #expect(list[0].payload["text"]?.stringValue == "iPhone")
}

@Test func knownVerbsDecode() throws {
    let data = Data(#"[{"verb":"http.request","request_id":"r1","url":"https://bbc.com"}]"#.utf8)
    let list = try PluginEnvelopeList.decode(data)
    #expect(list.count == 1)
    #expect(list[0].verb == .httpRequest)
    #expect(list[0].payload["url"]?.stringValue == "https://bbc.com")
}

@Test func verbClasses() {
    #expect(PluginVerb.httpRequest.classification == .continuation)
    #expect(PluginVerb.uiPresent.classification == .continuation)
    #expect(PluginVerb.resultEmit.classification == .terminal)
    #expect(PluginVerb.messagePost.classification == .terminal)
    #expect(PluginVerb.log.classification == .side)
}

@Test func exactBlacklistDoesNotMatchSibling() throws {
    let entry = try BlacklistEntry.parse("api.example.com")
    #expect(BlacklistMatcher.match(host: "api.example.com", entries: [entry]) != .none)
    #expect(BlacklistMatcher.match(host: "www.example.com", entries: [entry]) == .none)
}

@Test func suffixBlacklistDoesNotMatchApex() throws {
    let entry = try BlacklistEntry.parse("*.example.com")
    #expect(BlacklistMatcher.match(host: "www.example.com", entries: [entry]) != .none)
    #expect(BlacklistMatcher.match(host: "a.b.example.com", entries: [entry]) != .none)
    #expect(BlacklistMatcher.match(host: "example.com", entries: [entry]) == .none)
}

@Test func exactBeatsSuffix() throws {
    let suffix = try BlacklistEntry.parse("*.example.com")
    let exact = try BlacklistEntry.parse("api.example.com")
    switch BlacklistMatcher.match(host: "api.example.com", entries: [suffix, exact]) {
    case .hit(let hit):
        #expect(hit.kind == .exact)
        #expect(hit.pattern == "api.example.com")
    case .none:
        Issue.record("expected a hit")
    }
}

@Test func rejectPublicSuffixWildcards() {
    #expect(throws: BlacklistValidationError.rejectedPublicSuffix("com")) {
        _ = try BlacklistEntry.parse("*.com")
    }
    #expect(throws: BlacklistValidationError.rejectedPublicSuffix("co.uk")) {
        _ = try BlacklistEntry.parse("*.co.uk")
    }
    #expect(throws: BlacklistValidationError.rejectedPublicSuffix("xyz")) {
        _ = try BlacklistEntry.parse("*.xyz")
    }
    #expect(throws: BlacklistValidationError.self) {
        _ = try BlacklistEntry.parse("*")
    }
}

@Test func blacklistParseRejectsPortAndNormalizesCase() throws {
    #expect(throws: BlacklistValidationError.invalidPattern("api.example.com:443")) {
        _ = try BlacklistEntry.parse("api.example.com:443")
    }
    #expect(throws: BlacklistValidationError.invalidPattern("https://example.com")) {
        _ = try BlacklistEntry.parse("https://example.com")
    }
    let entry = try BlacklistEntry.parse("  API.Example.COM  ")
    #expect(entry.kind == .exact)
    #expect(entry.pattern == "api.example.com")
    #expect(entry.displayPattern == "api.example.com")
}

@Test func blacklistPolicyAllowsUnlessListed() throws {
    let listed = try BlacklistEntry.parse("*.bank.com")
    #expect(BlacklistHTTPPolicy.evaluate(host: "www.apple.com", blacklist: [listed], exceptions: []) == .allow)
    switch BlacklistHTTPPolicy.evaluate(host: "login.bank.com", blacklist: [listed], exceptions: []) {
    case .prompt(let entry):
        #expect(entry.displayPattern == "*.bank.com")
    case .allow:
        Issue.record("expected prompt")
    }
    #expect(BlacklistHTTPPolicy.evaluate(host: "bank.com", blacklist: [listed], exceptions: []) == .allow)
    let exception = try BlacklistEntry.parse("*.bank.com")
    #expect(
        BlacklistHTTPPolicy.evaluate(host: "login.bank.com", blacklist: [listed], exceptions: [exception]) == .allow
    )
}

@Test func ssrfDeniesLocalAndMetadata() {
    #expect(PluginSSRFPolicy.denyHostname("localhost") != nil)
    #expect(PluginSSRFPolicy.denyHostname("host.docker.internal") != nil)
    #expect(PluginSSRFPolicy.denyHostname("169.254.169.254") != nil)
    #expect(PluginSSRFPolicy.denyHostname("127.0.0.1") != nil)
    #expect(PluginSSRFPolicy.denyHostname("printer.local") != nil)
    #expect(PluginSSRFPolicy.denyHostname("bbc.com") == nil)
}

@Test func ssrfDeniesResolvedPrivateAndMapped() {
    #expect(PluginSSRFPolicy.denyResolvedAddress("10.0.0.5") != nil)
    #expect(PluginSSRFPolicy.denyResolvedAddress("192.168.1.1") != nil)
    #expect(PluginSSRFPolicy.denyResolvedAddress("::1") != nil)
    #expect(PluginSSRFPolicy.denyResolvedAddress("::ffff:127.0.0.1") != nil)
    #expect(PluginSSRFPolicy.denyResolvedAddress("1.1.1.1") == nil)
}

@Test func ssrfStripsAuthHeaders() {
    let stripped = PluginSSRFPolicy.stripRequestHeaders([
        "Authorization": "Bearer secret",
        "Content-Type": "application/json",
    ])
    #expect(stripped["Authorization"] == nil)
    #expect(stripped["Content-Type"] == "application/json")
}

@Test func ssrfLockstepLiteralsMatchEgressProxy() {
    // Must match EgressProxyConfiguration — do not import EgressProxy from Plugin.
    #expect(PluginSSRFPolicy.blockedHostnames == [
        "host.docker.internal",
        "gateway.docker.internal",
        "kubernetes.docker.internal",
        "metadata.google.internal",
        "metadata",
        "localhost",
    ])
    #expect(PluginSSRFPolicy.blockedIPv4CIDRs == [
        "0.0.0.0/8",
        "10.0.0.0/8",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "224.0.0.0/4",
        "255.255.255.255/32",
    ])
    for cidr in ["::1/128", "fc00::/7", "fe80::/10", "ff00::/8"] {
        #expect(PluginSSRFPolicy.blockedIPv6CIDRs.contains(cidr))
    }
}

@Test func denyFileScheme() {
    let url = URL(string: "file:///etc/passwd")!
    #expect(PluginSSRFPolicy.denyURL(url) == .disallowedScheme("file"))
}
