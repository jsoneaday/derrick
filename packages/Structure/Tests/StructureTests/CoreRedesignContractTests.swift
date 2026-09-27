import Foundation
import Testing
@testable import Structure

@Suite("Core redesign contracts")
struct CoreRedesignContractTests {
    @Test func actorAndAgentKindsRemainDistinct() {
        #expect(ActorKind.agent != ActorKind.pluginGuest)
        #expect(AgentKind.interactive != AgentKind.delegated)
        #expect(AgentRole.userFacing != AgentRole.worker)
    }

    @Test func agentRecordCarriesConfigurationReference() {
        let reference = AgentConfigurationReference(
            configurationID: "generalist",
            configurationVersion: 3,
            snapshotHash: "hash"
        )
        let record = AgentRecord(
            ref: AgentRef(sessionID: "session", agentID: "agent"),
            kind: .interactive,
            role: .userFacing,
            configurationReference: reference
        )

        #expect(record.configurationReference == reference)
        #expect(record.kind == .interactive)
    }

    @Test func capabilityRequestIdentifiesActor() {
        let request = CapabilityRequest(
            actor: ActorID(kind: .pluginGuest, value: "connector"),
            capability: "network.request",
            resource: "https://example.com",
            sessionID: "session"
        )

        #expect(request.actor.kind == .pluginGuest)
        #expect(request.capability.rawValue == "network.request")
    }

    @Test func processLaunchRequestIsTyped() {
        let request = ProcessLaunchRequest(
            processID: "guest-1",
            executable: "/usr/bin/guest",
            arguments: ["--input"],
            timeoutNanoseconds: 10
        )

        #expect(request.processID == "guest-1")
        #expect(request.arguments == ["--input"])
        #expect(request.timeoutNanoseconds == 10)
    }

    @Test func sideEffectRequestsRetainActorContext() throws {
        let request = HostHTTPRequest(
            requestID: "request-1",
            method: "GET",
            url: "https://example.com"
        )
        let sideEffect = NetworkSideEffectRequest(
            actor: ActorID(kind: .pluginGuest, value: "connector"),
            correlationID: "correlation-1",
            request: request
        )
        let data = try JSONEncoder().encode(sideEffect)
        let decoded = try JSONDecoder().decode(NetworkSideEffectRequest.self, from: data)

        #expect(decoded.actor.kind == .pluginGuest)
        #expect(decoded.request.url == "https://example.com")
    }
}
