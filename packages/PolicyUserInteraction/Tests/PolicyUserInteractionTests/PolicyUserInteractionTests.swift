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
