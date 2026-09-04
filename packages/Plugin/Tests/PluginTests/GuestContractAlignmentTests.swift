import Contract
import Foundation
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
}
