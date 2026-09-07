import Foundation
import Structure
import Testing

@Suite struct HostHTTPRequestSchemaTests {
    @Test func envelopeSchemaDeclaresJSONNotBody() throws {
        let schema = try GuestContract.loadSchemaObject(.envelopeList)
        let properties = try #require(
            (schema["items"] as? [String: Any])?["properties"] as? [String: Any]
        )
        #expect(properties["json"] != nil)
        #expect(properties["body"] == nil)
        let hostKeys = Set(["request_id", "method", "url", "auth_ref", "headers", "json"])
        #expect(hostKeys.isSubset(of: Set(properties.keys)))
    }

    @Test func guestJSONObjectDeserializesToHostHTTPRequest() throws {
        let envelopes = try PluginEnvelopeList.decode(
            Data(#"""
            [{"verb":"http.request","request_id":"send-1","method":"POST","url":"https://slack.com/api/chat.postMessage","headers":{"Content-Type":"application/json"},"json":{"channel":"C07FGNJS31T","text":"hello"}}]
            """#.utf8)
        )
        let request = try HostHTTPRequest(envelope: envelopes[0])
        #expect(request.requestID == "send-1")
        #expect(request.method == "POST")
        #expect(request.url == "https://slack.com/api/chat.postMessage")
        guard case .object(let object) = request.json else {
            Issue.record("Expected json object")
            return
        }
        #expect(object["channel"]?.stringValue == "C07FGNJS31T")
        #expect(object["text"]?.stringValue == "hello")
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body == #"{"channel":"C07FGNJS31T","text":"hello"}"#)
        #expect(request.wireHeaders["Content-Type"] == "application/json")
    }

    @Test func unofficialBodyFieldIsRejectedByEnvelopeSchema() {
        let json = #"""
        [{"verb":"http.request","request_id":"send-1","method":"POST","url":"https://example.com","body":"{\"channel\":\"C1\"}"}]
        """#
        #expect(throws: GuestContractError.self) {
            _ = try PluginEnvelopeList.decode(Data(json.utf8))
        }
    }

    @Test func pollHistoryJSONIsTheWireBody() throws {
        let envelopes = try PluginEnvelopeList.decode(
            Data(#"""
            [{"verb":"http.request","request_id":"poll-1","method":"POST","url":"https://slack.com/api/conversations.history","json":{"channel":"C07FGNJS31T","oldest":"1757192222.409000"}}]
            """#.utf8)
        )
        let request = try #require(try HostHTTPRequest.all(in: envelopes).first)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains(#""channel":"C07FGNJS31T""#))
        #expect(body.contains(#""oldest":"1757192222.409000""#))
        #expect(request.wireHeaders["Content-Type"] == "application/json")
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

    @Test func resultEmitDoesNotDecodeAsHTTPRequest() throws {
        let envelopes = try PluginEnvelopeList.decode(
            Data(#"[{"verb":"result.emit","summary":"ok"}]"#.utf8)
        )
        #expect(throws: HostHTTPRequestError.notAnHTTPRequest) {
            _ = try HostHTTPRequest(envelope: envelopes[0])
        }
        #expect(try HostHTTPRequest.all(in: envelopes).isEmpty)
    }

    @Test func runtimeTypedPayloadUsesHostHTTPRequest() throws {
        let envelopes = try PluginEnvelopeList.decode(
            Data(#"""
            [{"verb":"http.request","request_id":"send-1","method":"POST","url":"https://example.com","json":{"channel":"C1"}}]
            """#.utf8)
        )
        let runtime = try PluginRuntimeRequest(envelope: envelopes[0], sequence: 0)
        guard case .http(let http) = runtime.typedPayload else {
            Issue.record("Expected HostHTTPRequest typed payload")
            return
        }
        #expect(http.requestID == "send-1")
        guard case .object(let object) = http.json else {
            Issue.record("Expected json object on HostHTTPRequest")
            return
        }
        #expect(object["channel"]?.stringValue == "C1")
    }

    @Test func encodedHTTPResultsMatchHopEventSchema() throws {
        let event = PluginHopEvent(
            kind: .httpResults,
            httpResults: [
                HostHTTPResponse(
                    requestID: "send-1",
                    status: 200,
                    body: #"{"ok":true}"#
                ),
            ],
            params: ["messaging_op": .string("send_message")]
        )
        let data = try event.encodeValidated()
        let decoded = try PluginHopEvent.decodeValidated(data)
        #expect(decoded.httpResults?.first?.requestID == "send-1")
        #expect(decoded.httpResults?.first?.body == #"{"ok":true}"#)
    }

    @Test func hopEventSchemaRejectsUnknownHTTPResultProperty() {
        let json = #"{"kind":"http_results","http_results":[{"request_id":"a","status":200,"file_handle":"x"}]}"#
        #expect(throws: GuestContractError.self) {
            try GuestContractValidation.validateHopEventJSON(Data(json.utf8))
        }
    }
}

@Suite struct ConnectorPollCursorTests {
    @Test func unixSecondsUsesSixFractionalDigits() {
        let date = Date(timeIntervalSince1970: 1_757_192_222.409000158)
        #expect(ConnectorPollCursor.unixSeconds(date) == "1757192222.409000")
    }
}

@Suite struct ConnectorMessagingVendorFailureTests {
    @Test func detectsVendorErrorCopy() {
        let failed = ConnectorMessagingResult(
            terminalTitle: "Slack message send failed",
            terminalSummary: "Slack error: invalid_arguments"
        )
        #expect(failed.reportsVendorFailure)
        #expect(failed.terminalDetail == "Slack message send failed: Slack error: invalid_arguments")
    }

    @Test func emptySuccessfulPollIsNotAFailure() {
        let empty = ConnectorMessagingResult(
            terminalTitle: "Slack messages",
            terminalSummary: "Loaded 0 messages."
        )
        #expect(!empty.reportsVendorFailure)
    }
}
