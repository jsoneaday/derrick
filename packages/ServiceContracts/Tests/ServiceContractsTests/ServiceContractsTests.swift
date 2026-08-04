import Foundation
import Testing
@testable import ServiceContracts

@Suite struct ServiceContractsTests {
    @Test func healthRoundTrip() throws {
        let report = ServiceHealthReport(service: .agent, status: .ok, detail: "up")
        let data = try AgentServiceXPCCodec.encodeHealth(report)
        let decoded = try AgentServiceXPCCodec.decodeHealth(data)
        #expect(decoded.service == .agent)
        #expect(decoded.status == .ok)
        #expect(decoded.detail == "up")
    }

    @Test func principalLabels() {
        #expect(ServicePrincipal.ui.logLabel == "ui")
        #expect(ServicePrincipal.job(jobID: "j1").logLabel == "job:j1")
    }

    @Test func messageCodable() throws {
        let msg = ServiceMessage(
            from: .ui,
            to: .agent,
            type: .wakeAgent,
            principal: .ui,
            correlationId: "c1",
            payloadJSON: Data(#"{"x":1}"#.utf8)
        )
        let data = try JSONEncoder.service.encode(msg)
        let decoded = try JSONDecoder.service.decode(ServiceMessage.self, from: data)
        #expect(decoded.type == .wakeAgent)
        #expect(decoded.from == .ui)
        #expect(decoded.to == .agent)
    }

    @Test func serviceIDsMatchXPCNames() {
        #expect(DerrickServiceID.agent.xpcServiceName == "derrick.ui.AgentService")
        #expect(DerrickServiceID.job.xpcServiceName == "derrick.ui.JobService")
    }

    @Test func databaseDirectoryPrefersHostContainerFirst() {
        let parents = DerrickAppSupport.preferredDatabaseParentDirectories()
        #expect(!parents.isEmpty)
        let first = parents[0].path
        #expect(first.contains("Containers/\(DerrickAppSupport.hostAppBundleIdentifier)"))
        #expect(first.hasSuffix("Application Support") || first.contains("Application Support"))
    }

    @Test func turnRequestRoundTrip() throws {
        let request = AgentTurnRequest(
            turnID: "t1",
            sessionID: "s1",
            prompt: "hello",
            apiKey: "key",
            modelJSON: Data(#"{"openai":"gpt-5.6-luna"}"#.utf8)
        )
        let data = try AgentServiceXPCCodec.encodeTurnRequest(request)
        let decoded = try AgentServiceXPCCodec.decodeTurnRequest(data)
        #expect(decoded.turnID == "t1")
        #expect(decoded.prompt == "hello")
        #expect(decoded.sessionID == "s1")

        let chunk = AgentTurnChunkDTO(turnID: "t1", status: "complete", chunk: "hi", toolName: nil)
        let chunkData = try AgentServiceXPCCodec.encodeTurnChunk(chunk)
        let decodedChunk = try AgentServiceXPCCodec.decodeTurnChunk(chunkData)
        #expect(decodedChunk.chunk == "hi")
        #expect(decodedChunk.status == "complete")
    }

    @Test func messageSigningRoundTrip() {
        var msg = ServiceMessage(
            from: .job,
            to: .agent,
            type: .jobDue,
            principal: .job(jobID: "j1"),
            payloadJSON: Data(#"{"run":true}"#.utf8)
        )
        let key = ServiceMessageSigning.developmentKey()
        ServiceMessageSigning.sign(&msg, key: key)
        #expect(msg.signature != nil)
        #expect(ServiceMessageSigning.verify(msg, key: key))
        msg.signature = "deadbeef"
        #expect(ServiceMessageSigning.verify(msg, key: key) == false)
    }
}
