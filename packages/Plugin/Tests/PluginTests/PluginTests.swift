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
    #expect(PluginPrefix.typingHandle("/daily-news more") == nil)
    #expect(PluginPrefix.typingHandle("hello") == nil)
    #expect(PluginPrefix.typingHandle("//nope") == nil)
    #expect(PluginPrefix.matches(handle: "", pluginIDs: ["zeta", "alpha"]) == ["alpha", "zeta"])
    #expect(PluginPrefix.matches(handle: "daily", pluginIDs: ["daily-news", "daily-mail", "weather"]) == ["daily-mail", "daily-news"])
    #expect(PluginPrefix.matches(handle: "news", pluginIDs: ["daily-news-summary", "weather"]) == ["daily-news-summary"])
}

@Test func dailyNewsSampleIsAValidDraft() throws {
    let draft = DailyNewsSample.draft()
    #expect(draft.pluginID == "daily-news")
    #expect(try draft.pluginJSON().contains("daily-news"))
    #expect(draft.handle.contains("export function handle"))
    #expect(draft.handle.contains("netFetch"))
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
    #expect(PluginMarkup.strip("<![CDATA[Major incidents across UK]]>") == "Major incidents across UK")
    #expect(PluginMarkup.strip("<title><![CDATA[Hello]]></title>") == "Hello")
    #expect(PluginMarkup.naiveTagStripFinding("value.replace(/<[^>]*>/g, '')") != nil)
    #expect(PluginMarkup.naiveTagStripFinding("stripMarkup(block)") == nil)
    #expect(DerrickGuestTypeScript.verbUnion.contains("\"http.request\""))
    #expect(PluginEnvelopeSchema.ragSection.contains("TypeScript"))
    #expect(!DerrickGuestTypeScript.tsconfigJSON.contains("baseUrl"))
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
