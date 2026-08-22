import Testing
import AppEvents
@testable import PolicyUserInteraction

@Suite struct PolicyUserInteractionTests {
    @Test func factoryBuildsStaticFailure() {
        let event = PolicyUserEventFactory.staticValidationDenied(
            findings: ["host.docker.internal blocked"],
            scriptPreview: "import requests"
        )
        #expect(event.kind == .failure)
        #expect(event.source == .staticValidation)
        #expect(event.summary.contains("host.docker.internal"))
        #expect(event.priority == .userDecision)
    }

    @Test func factoryBuildsXPCValidationFailure() {
        let event = PolicyUserEventFactory.xpcValidationFailure(
            message: "XPC validation: executable is not allowed: /bin/zsh"
        )
        #expect(event.kind == .failure)
        #expect(event.source == .xpcValidation)
        #expect(event.title == "Docker helper rejected request")
        #expect(event.summary.contains("not allowed"))
    }

    @Test func factoryBuildsTypecheckFailed() {
        let event = PolicyUserEventFactory.typecheckFailed(
            message: "plugin.swift:1:1: error: expected expression"
        )
        #expect(event.kind == .failure)
        #expect(event.source == .system)
        #expect(event.title == "Swift check failed")
        #expect(event.summary.contains("expected expression"))
        #expect(event.detail?.contains("plugin.swift") == true)
    }

    @Test func factoryBuildsScriptExecutionFailed() {
        let event = PolicyUserEventFactory.scriptExecutionFailed(
            exitCode: 1,
            stderr: "Swift runtime error: invalid envelope output"
        )
        #expect(event.kind == .failure)
        #expect(event.source == .system)
        #expect(event.title == "Script execution failed")
        #expect(event.summary.contains("Swift runtime error"))
        #expect(event.detail?.contains("invalid envelope") == true)
    }

    @Test func factoryBuildsReadableSummaryForJSONDecodeError() {
        let stderr = """
        Swift.DecodingError.dataCorrupted
            at JSONDecoder.decode(_:from:)
        """
        let event = PolicyUserEventFactory.scriptExecutionFailed(exitCode: 1, stderr: stderr)
        #expect(event.summary.localizedCaseInsensitiveContains("JSON"))
        #expect(event.summary.localizedCaseInsensitiveContains("non-JSON") || event.summary.localizedCaseInsensitiveContains("HTML"))
        #expect(event.detail?.contains("DecodingError") == true)
    }

    @Test func factoryBuildsBlacklistHitRequest() {
        let event = PolicyUserEventFactory.blacklistHitRequest(
            url: "https://login.bank.com/x",
            displayPattern: "*.bank.com",
            kind: "suffix",
            pattern: "bank.com"
        )
        #expect(event.kind == .networkAccessRequest)
        #expect(event.title == "Network blacklist")
        #expect(event.summary.contains("login.bank.com"))
        #expect(event.summary.contains("*.bank.com"))
        #expect(event.rememberKey == "egress.blacklist.remove:suffix:bank.com")
    }

    @Test func factoryBuildsEgressDenied() {
        let event = PolicyUserEventFactory.egressDenied(
            detail: "UNAUTHORIZED_EGRESS destination=reactjs.org"
        )
        #expect(event.kind == .failure)
        #expect(event.source == .egressProxy)
        #expect(event.title == "Network request blocked")
        #expect(event.detail?.contains("reactjs.org") == true)
    }

    @Test func factoryBuildsEgressAccessRequest() {
        let event = PolicyUserEventFactory.egressAccessRequest(host: "api.reactjs.org")
        #expect(event.kind == .networkAccessRequest)
        #expect(event.source == .egressProxy)
        #expect(event.summary == "Allow *.reactjs.org?")
        #expect(event.detail?.contains("reactjs.org") == true)
    }

    @Test func factoryBuildsBatchedEgressAccessRequest() {
        let event = PolicyUserEventFactory.egressAccessRequest(
            hosts: ["m.media-amazon.com", "images-na.ssl-images-amazon.com", "c.amazon-adsystem.com"]
        )
        #expect(event.kind == .networkAccessRequest)
        #expect(event.summary == "Allow these domains and their subdomains?")
        #expect(event.payloadPreview?.contains("m.media-amazon.com") == true)
        #expect(event.payloadPreview?.contains("amazon-adsystem.com") == true)
        #expect(event.detail?.localizedCaseInsensitiveContains("always saves") == true)
    }

    @Test func approvalRequiredIsDecisionRequesting() async {
        let bus = AppEventBus()
        let event = PolicyUserEventFactory.approvalRequired(
            summary: "Allow tool?",
            toolName: "script_exec",
            payloadPreview: "{\"x\":1}"
        )
        await bus.subscribe { anyEvent in
            if anyEvent.id == event.id {
                await bus.completeDecision(id: event.id, decision: PolicyUserDecision.approved(actor: "test"))
            }
        }
        let decision = await bus.initDecision(event)
        #expect(decision == .approved(actor: "test"))
    }
}
