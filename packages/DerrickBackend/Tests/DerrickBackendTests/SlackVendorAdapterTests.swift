import Foundation
import Structure
import Testing
@testable import DerrickBackend

@Suite struct SlackVendorAdapterTests {
    @Test func parseDisplayNamePrefersProfileDisplayName() {
        let json = """
        {"ok":true,"user":{"id":"U07FKG8DV19","name":"david.choi","real_name":"David Choi","profile":{"display_name":"David"}}}
        """.data(using: .utf8)!
        #expect(SlackUserDisplayNameResolver.parseDisplayName(from: json) == "David")
    }

    @Test func parseDisplayNameFallsBackToRealName() {
        let json = """
        {"ok":true,"user":{"id":"U07FKG8DV19","name":"david.choi","real_name":"David Choi","profile":{"display_name":""}}}
        """.data(using: .utf8)!
        #expect(SlackUserDisplayNameResolver.parseDisplayName(from: json) == "David Choi")
    }

    @Test func parseDisplayNameFallsBackToUsername() {
        let json = """
        {"ok":true,"user":{"id":"U07FKG8DV19","name":"david.choi","real_name":"","profile":{}}}
        """.data(using: .utf8)!
        #expect(SlackUserDisplayNameResolver.parseDisplayName(from: json) == "david.choi")
    }

    @Test func parseBotUserIDFromAuthTestPayload() {
        let json = Data(#"{"ok":true,"user_id":"U07BOT","bot_id":"B07BOT"}"#.utf8)
        #expect(SlackBotIdentityResolver.parseBotUserID(from: json) == "U07BOT")
    }

    @Test func pollHistoryJSONIsRewrittenToForm() throws {
        let envelopes = try PluginEnvelopeList.decode(
            Data(#"""
            [{"verb":"http.request","request_id":"poll-1","method":"POST","url":"https://slack.com/api/conversations.history","json":{"channel":"C07FGNJS31T","oldest":"1757192222.409000"}}]
            """#.utf8)
        )
        let request = try #require(try HostHTTPRequest.all(in: envelopes).first)
        let wire = SlackWebAPIFormEncoding.rewritten(request)
        #expect(wire.headers["Content-Type"] == "application/x-www-form-urlencoded")
        let form = String(decoding: try #require(wire.body), as: UTF8.self)
        #expect(form.contains("channel=C07FGNJS31T"))
        #expect(form.contains("oldest=1757192222.409000"))
        #expect(form.contains("inclusive=true"))
    }

    @Test func slackReplyJSONIsSentAsFormFields() throws {
        let envelopes = try PluginEnvelopeList.decode(
            Data(#"""
            [{"verb":"http.request","request_id":"replies-1","method":"POST","url":"https://slack.com/api/conversations.replies","json":{"channel":"C07FGNJS31T","ts":"1788797826.445789"}}]
            """#.utf8)
        )
        let request = try #require(try HostHTTPRequest.all(in: envelopes).first)
        let wire = SlackWebAPIFormEncoding.rewritten(request)
        #expect(wire.headers["Content-Type"] == "application/x-www-form-urlencoded")
        let form = String(decoding: try #require(wire.body), as: UTF8.self)
        #expect(form == "channel=C07FGNJS31T&ts=1788797826.445789")
    }

    @Test func slackHistoryGETAddsInclusiveWhenOldestIsSet() {
        let url = "https://slack.com/api/conversations.history?channel=C07FGNJS31T&limit=200&oldest=1788805364.385569"
        let rewritten = SlackWebAPIFormEncoding.rewrittenURL(url)
        #expect(rewritten.contains("inclusive=true"))
        #expect(rewritten.contains("oldest=1788805364.385569"))
    }

    @Test func slackChatPostMessageStaysJSON() throws {
        let envelopes = try PluginEnvelopeList.decode(
            Data(#"""
            [{"verb":"http.request","request_id":"send-1","method":"POST","url":"https://slack.com/api/chat.postMessage","headers":{"Content-Type":"application/json"},"json":{"channel":"C1","text":"hello"}}]
            """#.utf8)
        )
        let request = try #require(try HostHTTPRequest.all(in: envelopes).first)
        let wire = SlackWebAPIFormEncoding.rewritten(request)
        #expect(wire.headers["Content-Type"] == "application/json")
        let body = String(decoding: try #require(wire.body), as: UTF8.self)
        #expect(body == #"{"channel":"C1","text":"hello"}"#)
    }
}
