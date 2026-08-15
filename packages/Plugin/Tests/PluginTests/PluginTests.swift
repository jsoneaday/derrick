import Testing
import Foundation
@testable import Plugin

@Test func unknownVerbFailsClosed() throws {
    let data = Data(#"[{"verb":"call_tool","url":"https://evil.example"}]"#.utf8)
    #expect(throws: PluginEnvelopeError.unknownVerb("call_tool")) {
        _ = try PluginEnvelopeList.decode(data)
    }
}

@Test func handleMustReturnArray() throws {
    let data = Data(#"{"verb":"log","message":"x"}"#.utf8)
    #expect(throws: PluginEnvelopeError.notAnArray) {
        _ = try PluginEnvelopeList.decode(data)
    }
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
    #expect(throws: BlacklistValidationError.self) {
        _ = try BlacklistEntry.parse("*")
    }
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
