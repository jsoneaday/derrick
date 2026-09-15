import Foundation
import Structure
import Testing

@Suite struct ScriptExecContractTests {
    @Test func protocolJSONLoadsAndMatchesRules() throws {
        let document = try ScriptExecContractStore.loadProtocol()
        #expect(document.version == 1)
        #expect(document.runtime.language == "go")
        #expect(document.review.failFast)
        #expect(document.review.checks.count == 4)
        #expect(document.rules.guestHasNoNetwork)
        #expect(document.output.fields["content"]?.purpose.contains("plain-text") == true)
        #expect(document.pluginFactory.manifest.hostCreatesManifest)
        #expect(document.pluginFactory.builder.connectorTestInputUsesHopsArray)
        #expect(document.pluginFactory.review.compilationSuccessNotApproval)
    }

    @Test func pluginFactoryPromptsReferenceContractJSON() {
        let builder = ScriptExecContractPrompts.pluginFactoryBuilderGuide()
        let reviewer = ScriptExecContractPrompts.pluginFactoryReviewerGuide()
        #expect(builder.contains("plugin_factory"))
        #expect(builder.contains("--- script-exec-contract.json ---"))
        #expect(reviewer.contains("plugin_factory.review"))
        #expect(reviewer.contains("If a guest rule is not in the JSON"))
    }

    @Test func fingerprintMatchesGeneratedFile() throws {
        #expect(try ScriptExecContractStore.computeFingerprint() == ScriptExecContractFingerprint.sha256)
        #expect(ScriptExecContractFingerprint.sourceFiles == ScriptExecContractStore.fingerprintSources)
    }

    @Test func bundledContractSatisfiesItsSchema() throws {
        try ScriptExecContractIntegrity.validateBundledGraph()
    }

    @Test func reviewerGuideDumpsCanonicalJSON() throws {
        let guide = ScriptExecContractPrompts.reviewerGuide()
        #expect(guide.contains("If a rule is not in the JSON"))
        #expect(guide.contains("--- script-exec-contract.json ---"))
        #expect(guide.contains(try ScriptExecContractStore.loadProtocolText()))
        #expect(guide.contains("--- \(GuestContract.Schema.envelopeList.rawValue) ---"))
    }

    @Test func builderGuideDumpsWireSchemas() throws {
        let guide = ScriptExecContractPrompts.builderGuide()
        #expect(guide.contains("--- \(GuestContract.Schema.hopEvent.rawValue) ---"))
        #expect(guide.contains("--- \(GuestContract.Schema.guestRuntime.rawValue) ---"))
    }
}
