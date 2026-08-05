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

    @Test func mcpToolCallRoundTrip() throws {
        let wire = HelperModelWire(provider: "openai", model: "gpt-5.6-luna")
        let wireJSON = try HelperModelWire.encodeJSON(wire)
        let request = MCPToolCallRequest(
            principal: .agent(sessionID: "s1", agentID: "ui"),
            toolName: "python_script_exec",
            argumentsJSON: #"{"script":"print(1)"}"#,
            helperAPIKey: "sk-test",
            helperReviewerModelJSON: wireJSON
        )
        let data = try MCPServiceXPCCodec.encodeToolCallRequest(request)
        let decoded = try MCPServiceXPCCodec.decodeToolCallRequest(data)
        #expect(decoded.toolName == "python_script_exec")
        #expect(decoded.principal.logLabel.contains("agent:"))
        #expect(decoded.helperAPIKey == "sk-test")
        #expect(decoded.helperReviewerModelJSON == wireJSON)
        let decodedWire = try HelperModelWire.decodeJSON(decoded.helperReviewerModelJSON!)
        #expect(decodedWire.provider == "openai")
        #expect(decodedWire.model == "gpt-5.6-luna")

        let result = MCPToolCallResultDTO(requestID: decoded.requestID, ok: true, text: "ok")
        let rData = try MCPServiceXPCCodec.encodeToolCallResult(result)
        let rDecoded = try MCPServiceXPCCodec.decodeToolCallResult(rData)
        #expect(rDecoded.ok == true)
        #expect(rDecoded.text == "ok")
    }

    @Test func mcpServiceIDAndSearchRoundTrip() throws {
        #expect(DerrickServiceID.mcp.xpcServiceName == "derrick.ui.MCPService")
        let search = MCPToolSearchRequest(principal: .system, query: "python")
        let data = try MCPServiceXPCCodec.encodeToolSearchRequest(search)
        let decoded = try MCPServiceXPCCodec.decodeToolSearchRequest(data)
        #expect(decoded.query == "python")
        #expect(decoded.principal == .system)
    }

    @Test func approvalDTORoundTrip() throws {
        let request = AgentApprovalRequestDTO(
            approvalID: "a1",
            turnID: "t1",
            sessionID: "s1",
            toolName: "python_script_exec",
            argumentsJSON: #"{"code":"print(1)"}"#,
            requiredFields: ["review"]
        )
        let data = try AgentServiceXPCCodec.encodeApprovalRequest(request)
        let decoded = try AgentServiceXPCCodec.decodeApprovalRequest(data)
        #expect(decoded.toolName == "python_script_exec")
        #expect(decoded.requiredFields == ["review"])

        let decision = AgentApprovalDecisionDTO(
            approvalID: "a1",
            approved: true,
            editedArgumentsJSON: request.argumentsJSON,
            actor: "user"
        )
        let dData = try AgentServiceXPCCodec.encodeApprovalDecision(decision)
        let dDecoded = try AgentServiceXPCCodec.decodeApprovalDecision(dData)
        #expect(dDecoded.approved == true)
        #expect(dDecoded.actor == "user")
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

    @Test func signedToolCallEnvelopeRoundTrip() throws {
        let key = ServiceMessageSigning.developmentKey(seed: "test-messages-secret")
        let request = MCPToolCallRequest(
            principal: .agent(sessionID: "s1", agentID: "ui"),
            toolName: "python_script_exec",
            argumentsJSON: #"{"script":"print(1)"}"#,
            helperAPIKey: "sk-test"
        )
        let data = try MCPServiceXPCCodec.encodeSignedToolCallRequest(request, key: key)
        let decoded = try MCPServiceXPCCodec.decodeSignedToolCallRequest(data, key: key)
        #expect(decoded.toolName == "python_script_exec")
        #expect(decoded.helperAPIKey == "sk-test")

        // Tamper fails verify
        var message = try JSONDecoder.service.decode(ServiceMessage.self, from: data)
        message = ServiceMessage(
            id: message.id,
            createdAt: message.createdAt,
            from: message.from,
            to: message.to,
            type: message.type,
            principal: message.principal,
            correlationId: message.correlationId,
            payloadJSON: Data(#"{"toolName":"evil"}"#.utf8),
            signature: message.signature
        )
        let tampered = try JSONEncoder.service.encode(message)
        #expect(throws: ServiceMessageEnvelope.Error.invalidSignature) {
            _ = try MCPServiceXPCCodec.decodeSignedToolCallRequest(tampered, key: key)
        }
    }

    @Test func signedTurnEnvelopeRoundTrip() throws {
        let key = ServiceMessageSigning.developmentKey(seed: "test-messages-secret")
        let request = AgentTurnRequest(
            prompt: "hello",
            apiKey: "sk",
            modelJSON: Data(#"{"openai":{"_0":"gpt-5.6-luna"}}"#.utf8)
        )
        let data = try AgentServiceXPCCodec.encodeSignedTurnRequest(request, key: key)
        let decoded = try AgentServiceXPCCodec.decodeSignedTurnRequest(data, key: key)
        #expect(decoded.prompt == "hello")
    }

    @Test func debugModeRequiresMessagesSecretKey() throws {
        MessagesSecretKey.resetCacheForTesting()
        #expect(throws: MessagesSecretKeyError.missingDebugSecret) {
            _ = try MessagesSecretKey.resolveSecretString(
                environment: ["IS_DEBUG": "true"],
                bundleURL: URL(fileURLWithPath: "/tmp"),
                currentDirectoryURL: URL(fileURLWithPath: "/tmp")
            )
        }
        MessagesSecretKey.resetCacheForTesting()
        let secret = try MessagesSecretKey.resolveSecretString(
            environment: ["IS_DEBUG": "true", "MESSAGES_SECRET_KEY": "dev-secret-xyz"],
            bundleURL: URL(fileURLWithPath: "/tmp"),
            currentDirectoryURL: URL(fileURLWithPath: "/tmp")
        )
        #expect(secret == "dev-secret-xyz")
        MessagesSecretKey.resetCacheForTesting()
    }
}
