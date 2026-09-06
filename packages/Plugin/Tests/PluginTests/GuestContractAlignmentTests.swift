import Foundation
import Structure
import Testing
@testable import Plugin

@Suite struct GuestContractAlignmentTests {
    @Test func pluginVerbsMatchEnvelopeSchema() throws {
        let schemaVerbs = Set(try GuestContract.officialEnvelopeVerbs())
        let swiftVerbs = Set(PluginVerb.allCases.map(\.rawValue))
        #expect(swiftVerbs == schemaVerbs)
    }

    @Test func pluginEventKindsMatchHopSchema() throws {
        let schemaKinds = Set(try GuestContract.officialHopEventKinds())
        let swiftKinds = Set(PluginEventKind.allCases.map(\.rawValue))
        #expect(swiftKinds == schemaKinds)
    }

    @Test func hostHTTPRequestFieldsAreOnTheEnvelopeSchema() throws {
        let schema = try GuestContract.loadSchemaObject(.envelopeList)
        let properties = try #require(
            (schema["items"] as? [String: Any])?["properties"] as? [String: Any]
        )
        let hostKeys = Set(["request_id", "method", "url", "auth_ref", "headers", "json"])
        #expect(hostKeys.isSubset(of: Set(properties.keys)))
        #expect(properties["body"] == nil)
        #expect(properties["type"] == nil)
        #expect((schema["items"] as? [String: Any])?["additionalProperties"] as? Bool == false)
    }
}
