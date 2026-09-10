import Foundation
import Structure
import Testing

@Suite struct GuestContractTests {
    @Test func bundledSchemasLoad() throws {
        for schema in GuestContract.Schema.allCases {
            let text = try GuestContract.loadSchemaText(schema)
            #expect(!text.isEmpty)
        }
    }

    @Test func guestRuntimeSchemaRequiresGoLanguage() throws {
        let schema = try GuestContract.loadSchemaObject(.guestRuntime)
        let language = (schema["properties"] as? [String: Any])?["language"] as? [String: Any]
        #expect(language?["const"] as? String == "go")
    }

    @Test func executionContextSchemaExposesWorkflowKinds() throws {
        let kinds = try GuestContract.officialWorkflowKinds()
        #expect(kinds.contains("plugin_factory_create"))
        #expect(kinds.contains("connector_auth_discover"))
        #expect(kinds.contains("none"))
    }

    @Test func envelopeListValidationAcceptsMinimalRequest() throws {
        let json = """
        [{"verb":"http.request","request_id":"a","method":"GET","url":"https://example.com"}]
        """
        try GuestContractValidation.validateEnvelopeListJSON(Data(json.utf8))
    }

    @Test func envelopeListValidationAcceptsJSONObjectBody() throws {
        let json = """
        [{"verb":"http.request","request_id":"send-1","method":"POST","url":"https://slack.com/api/chat.postMessage","json":{"channel":"C1","text":"hi"}}]
        """
        try GuestContractValidation.validateEnvelopeListJSON(Data(json.utf8))
    }

    @Test func envelopeListValidationRejectsUnknownVerb() {
        let json = #" [{"verb":"network.fetch","url":"https://example.com"}] "#
        #expect(throws: GuestContractError.self) {
            try GuestContractValidation.validateEnvelopeListJSON(Data(json.utf8))
        }
    }

    @Test func hopEventValidationAcceptsManualKind() throws {
        let json = #" {"kind":"manual","params":{}} "#
        try GuestContractValidation.validateHopEventJSON(Data(json.utf8))
    }

    @Test func hopEventValidationRejectsUnknownKind() {
        let json = #" {"kind":"slack_poll"} "#
        #expect(throws: GuestContractError.self) {
            try GuestContractValidation.validateHopEventJSON(Data(json.utf8))
        }
    }

    @Test func hopEventValidationUsesParamsSchemaRef() {
        #expect(throws: GuestContractError.self) {
            try GuestContract.validate(
                json: Data(#"{"kind":"manual","params":{"messaging_op":"react"}}"#.utf8),
                against: .hopEvent
            )
        }
    }

    @Test func hopEventValidationRejectsUnknownProperty() {
        #expect(throws: GuestContractError.self) {
            try GuestContract.validate(
                json: Data(#"{"kind":"manual","foo":1}"#.utf8),
                against: .hopEvent
            )
        }
    }

    @Test func envelopeListValidationRejectsUnknownProperty() {
        let json = #"[{"verb":"http.request","request_id":"a","method":"GET","url":"https://example.com","body":"x"}]"#
        #expect(throws: GuestContractError.self) {
            try GuestContractValidation.validateEnvelopeListJSON(Data(json.utf8))
        }
    }

    @Test func envelopeListValidationRejectsVerbAlias() {
        let json = #"[{"verb":"http","url":"https://example.com"}]"#
        #expect(throws: GuestContractError.self) {
            try GuestContractValidation.validateEnvelopeListJSON(Data(json.utf8))
        }
    }

    @Test func envelopeListValidationRejectsTypeAlias() {
        let json = #"[{"type":"http.request","url":"https://example.com"}]"#
        #expect(throws: GuestContractError.self) {
            try GuestContractValidation.validateEnvelopeListJSON(Data(json.utf8))
        }
    }

    @Test func hopEventValidationRejectsUnknownParamProperty() {
        #expect(throws: GuestContractError.self) {
            try GuestContract.validate(
                json: Data(#"{"kind":"manual","params":{"messaging_op":"sync_threads","channel":"C1"}}"#.utf8),
                against: .hopEvent
            )
        }
    }

    @Test func envelopeListValidationRejectsIncompleteThread() {
        let json = #"[{"verb":"result.emit","threads":[{"vendor_thread_id":"C1"}]}]"#
        #expect(throws: GuestContractError.self) {
            try GuestContract.validate(json: Data(json.utf8), against: .envelopeList)
        }
    }

    @Test func webCrawlerResultValidationAcceptsMinimalSuccess() throws {
        let json = """
        {"ok":true,"start_url":"https://example.com/","pages":[],"stop_reason":"completed","requests_made":0,"bytes_read":0,"truncated":false,"diagnostics":[]}
        """
        try GuestContractValidation.validateWebCrawlerResultJSON(Data(json.utf8))
    }

    @Test func webCrawlerResultValidationRejectsNullDiagnostics() {
        let json = """
        {"ok":true,"start_url":"https://example.com/","pages":[],"stop_reason":"completed","requests_made":0,"bytes_read":0,"truncated":false,"diagnostics":null}
        """
        #expect(throws: GuestContractError.self) {
            try GuestContractValidation.validateWebCrawlerResultJSON(Data(json.utf8))
        }
    }

    @Test func fileExtractorResultValidationAcceptsMinimalSuccess() throws {
        let json = """
        {"ok":true,"operation":"extract","files":[],"diagnostics":[]}
        """
        try GuestContractValidation.validateFileExtractorResultJSON(Data(json.utf8))
    }

    @Test func fileExtractorResultValidationRejectsNullFiles() {
        let json = """
        {"ok":false,"operation":"extract","files":null,"diagnostics":[]}
        """
        #expect(throws: GuestContractError.self) {
            try GuestContractValidation.validateFileExtractorResultJSON(Data(json.utf8))
        }
    }

}
