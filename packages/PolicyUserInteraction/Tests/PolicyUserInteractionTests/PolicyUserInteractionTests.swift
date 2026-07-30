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

    @Test func factoryBuildsScriptExecutionFailed() {
        let event = PolicyUserEventFactory.scriptExecutionFailed(
            exitCode: 1,
            stderr: "Traceback (most recent call last):\nValueError: boom"
        )
        #expect(event.kind == .failure)
        #expect(event.source == .system)
        #expect(event.title == "Script execution failed")
        #expect(event.summary.contains("ValueError"))
        #expect(event.detail?.contains("Traceback") == true)
    }

    @Test func factoryBuildsReadableSummaryForJSONDecodeError() {
        let stderr = """
        Traceback (most recent call last):
          File "/usr/lib/python3.13/json/decoder.py", line 345, in decode
            obj, end = self.raw_decode(s, idx=_w(s, 0).end())
        json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)
        """
        let event = PolicyUserEventFactory.scriptExecutionFailed(exitCode: 1, stderr: stderr)
        #expect(event.summary.localizedCaseInsensitiveContains("JSON"))
        #expect(event.summary.localizedCaseInsensitiveContains("non-JSON") || event.summary.localizedCaseInsensitiveContains("HTML"))
        #expect(event.detail?.contains("JSONDecodeError") == true)
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
        #expect(event.summary.contains("api.reactjs.org"))
        #expect(event.detail?.contains("reactjs.org") == true)
    }

    @Test func approvalRequiredIsDecisionRequesting() async {
        let bus = AppEventBus()
        let event = PolicyUserEventFactory.approvalRequired(
            summary: "Allow tool?",
            toolName: "python_script_exec",
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
