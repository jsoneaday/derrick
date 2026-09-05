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

    @Test func executionContextSchemaExposesWorkflowKinds() throws {
        let kinds = try GuestContract.officialWorkflowKinds()
        #expect(kinds.contains("plugin_factory_create"))
        #expect(kinds.contains("none"))
    }

    @Test func envelopeListValidationAcceptsMinimalRequest() throws {
        let json = """
        [{"verb":"http.request","request_id":"a","method":"GET","url":"https://example.com"}]
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

    @Test func envelopeVerbsIncludeHttpRequestAndResultEmit() throws {
        let verbs = try GuestContract.officialEnvelopeVerbs()
        #expect(verbs.contains("http.request"))
        #expect(verbs.contains("result.emit"))
        #expect(verbs.contains("message.post"))
    }
}
