import Foundation
import Testing
@testable import Structure

@Suite struct AppLayerServicesWireTests {
    private func appGroupCrossProcessStorageIsAvailable() -> Bool {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: DerrickAppSupport.applicationGroupIdentifier
        ) else {
            return false
        }
        let probe = container.appendingPathComponent("applayerservices_ci_probe.txt")
        do {
            try Data("probe".utf8).write(to: probe, options: .atomic)
            try FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    @Test func toolExecutionOutcomeRoundTripsOutputAndDiagnostics() throws {
        let outcome = ToolExecutionOutcome.failure(
            status: .blocked,
            stage: .review,
            diagnostics: [
                ToolExecutionOutcome.Diagnostic(
                    code: "functional_mismatch",
                    message: "The result did not satisfy the request."
                )
            ],
            retry: ToolExecutionOutcome.Retry(
                allowed: true,
                attempt: 2,
                maxAttempts: 3
            )
        )

        let decoded = try #require(
            ToolExecutionOutcome.decode(from: try outcome.encodedJSON())
        )
        #expect(decoded.status == .blocked)
        #expect(decoded.stage == .review)
        #expect(decoded.failureSummary == "The result did not satisfy the request.")
        #expect(decoded.retry?.attempt == 2)
        #expect(decoded.retry?.maxAttempts == 3)
    }

    @Test func egressBlacklistDTOsRoundTrip() throws {
        let entry = EgressBlacklistEntryDTO(
            id: "e1",
            kind: "suffix",
            pattern: "example.com",
            displayPattern: "*.example.com"
        )
        let listed = try DerrickDaemonXPCCodec.decodeBlacklistList(
            try DerrickDaemonXPCCodec.encodeBlacklistList(EgressBlacklistListResult(entries: [entry]))
        )
        #expect(listed.entries == [entry])
        let add = try DerrickDaemonXPCCodec.decodeBlacklistAddRequest(
            try DerrickDaemonXPCCodec.encodeBlacklistAddRequest(EgressBlacklistAddRequest(pattern: "*.bank.com"))
        )
        #expect(add.pattern == "*.bank.com")
        let remove = try DerrickDaemonXPCCodec.decodeBlacklistRemoveRequest(
            try DerrickDaemonXPCCodec.encodeBlacklistRemoveRequest(EgressBlacklistRemoveRequest(id: "e1"))
        )
        #expect(remove.id == "e1")
    }

    @Test func healthRoundTrip() throws {
        let report = ServiceHealthReport(
            service: .agent,
            status: .ok,
            detail: "up",
            guestRuntimeImage: DerrickGuestRuntime.swiftPluginDockerImage
        )
        let data = try AgentServiceXPCCodec.encodeHealth(report)
        let decoded = try AgentServiceXPCCodec.decodeHealth(data)
        #expect(decoded.service == .agent)
        #expect(decoded.status == .ok)
        #expect(decoded.detail == "up")
        #expect(decoded.guestRuntimeImage == DerrickGuestRuntime.swiftPluginDockerImage)
        #expect(decoded.guestRuntimeImage == "swiftlang/swift:nightly-6.4.x-noble")
        #expect(decoded.executableFingerprint == nil)
    }

    @Test func scriptExecReviewerPromptLoadsFromBundledContract() {
        let scriptReviewer = ScriptExecContractPrompts.reviewerGuide()
        #expect(scriptReviewer.contains("script-exec-contract.json"))
        #expect(scriptReviewer.contains("intent_alignment"))
        #expect(scriptReviewer.contains("If a rule is not in the JSON"))
    }

    @Test func healthDecodesLegacyPayloadWithoutGuestRuntime() throws {
        let json = """
        {"service":"derrick.ui.AgentService","status":"ok","protocolVersion":1,"serviceVersion":"0.1.0","pid":1,"checkedAt":0}
        """
        let decoded = try JSONDecoder().decode(ServiceHealthReport.self, from: Data(json.utf8))
        #expect(decoded.guestRuntimeImage == nil)
        #expect(decoded.executableFingerprint == nil)
    }

    @Test func healthRoundTripsExecutableFingerprint() throws {
        let report = ServiceHealthReport(
            service: .daemon,
            status: .ok,
            guestRuntimeImage: DerrickGuestRuntime.swiftPluginDockerImage,
            executableFingerprint: "1-2-3.000"
        )
        let data = try DerrickDaemonXPCCodec.encodeHealth(report)
        let decoded = try DerrickDaemonXPCCodec.decodeHealth(data)
        #expect(decoded.executableFingerprint == "1-2-3.000")
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

    @Test func daemonSingletonLockURLUsesHomeApplicationSupport() {
        let url = DerrickAppSupport.daemonSingletonLockURL()
        #expect(url.lastPathComponent == "derrickd.lock")
        #expect(url.path.contains("Library/Application Support/Derrick"))
    }

    @Test func sharedDatabaseUnavailableErrorIsLocalized() {
        let error = DerrickAppSupportError.sharedDatabaseUnavailable("test detail")
        #expect(error.errorDescription == "test detail")
    }

    @Test func databaseDirectoryPrefersAppGroupThenHostContainer() {
        let parents = DerrickAppSupport.preferredDatabaseParentDirectories()
        #expect(!parents.isEmpty)
        // App Group (when available) first; host container always present as a candidate.
        let paths = parents.map(\.path)
        #expect(paths.contains { $0.contains("Containers/\(DerrickAppSupport.hostAppBundleIdentifier)") })
        if let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: DerrickAppSupport.applicationGroupIdentifier
        ) {
            #expect(parents[0].path.hasPrefix(group.path))
        }
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

        let chunk = AgentTurnChunkDTO(
            turnID: "t1",
            sessionID: "s1",
            status: "tool_call",
            chunk: "Building",
            toolName: "plugin_factory_build",
            isProgress: true
        )
        let chunkData = try AgentServiceXPCCodec.encodeTurnChunk(chunk)
        let decodedChunk = try AgentServiceXPCCodec.decodeTurnChunk(chunkData)
        #expect(decodedChunk.chunk == "Building")
        #expect(decodedChunk.status == "tool_call")
        #expect(decodedChunk.sessionID == "s1")
        #expect(decodedChunk.isProgress)
    }

    @Test func mcpToolCallRoundTrip() throws {
        let wire = HelperModelWire(provider: "openai", model: "gpt-5.6-luna")
        let wireJSON = try HelperModelWire.encodeJSON(wire)
        let request = MCPToolCallRequest(
            principal: .agent(sessionID: "s1", agentID: "ui"),
            toolName: "script_exec",
            argumentsJSON: #"{"script":"print(1)"}"#,
            helperAPIKey: "sk-test",
            helperReviewerModelJSON: wireJSON,
            pluginFactoryCreationActive: true
        )
        let data = try MCPServiceXPCCodec.encodeToolCallRequest(request)
        let decoded = try MCPServiceXPCCodec.decodeToolCallRequest(data)
        #expect(decoded.toolName == "script_exec")
        #expect(decoded.principal.logLabel.contains("agent:"))
        #expect(decoded.helperAPIKey == "sk-test")
        #expect(decoded.helperReviewerModelJSON == wireJSON)
        #expect(decoded.pluginFactoryCreationActive == true)
        let decodedWire = try HelperModelWire.decodeJSON(decoded.helperReviewerModelJSON!)
        #expect(decodedWire.provider == "openai")
        #expect(decodedWire.model == "gpt-5.6-luna")

        let result = MCPToolCallResultDTO(requestID: decoded.requestID, ok: true, text: "ok")
        let rData = try MCPServiceXPCCodec.encodeToolCallResult(result)
        let rDecoded = try MCPServiceXPCCodec.decodeToolCallResult(rData)
        #expect(rDecoded.ok == true)
        #expect(rDecoded.text == "ok")
    }

    @Test func mcpToolCallTimeouts() {
        #expect(MCPToolCallTimeouts.nanoseconds(forToolName: "web.crawl")
            == MCPToolCallTimeouts.longRunningNanoseconds)
        #expect(MCPToolCallTimeouts.nanoseconds(forToolName: "plugin_factory_build")
            == MCPToolCallTimeouts.longRunningNanoseconds)
        #expect(MCPToolCallTimeouts.nanoseconds(forToolName: "plugin.invoke")
            == MCPToolCallTimeouts.pluginInvokeNanoseconds)
        #expect(MCPToolCallTimeouts.nanoseconds(forToolName: "memory_search")
            == MCPToolCallTimeouts.standardNanoseconds)
    }

    @Test func connectorMessagingXPCCodecRoundTrip() throws {
        let submit = ConnectorOperationRequest(
            operationID: "op-1",
            pluginID: "slack-connector",
            kind: .send,
            vendorThreadID: "C1",
            threadID: "thread-1",
            text: "hello"
        )
        #expect(
            try ConnectorMessagingXPCCodec.decodeSubmit(
                try ConnectorMessagingXPCCodec.encodeSubmit(submit)
            ) == submit
        )
    }

    @Test func mcpServiceIDAndSearchRoundTrip() throws {
        #expect(DerrickServiceID.mcp.xpcServiceName == "derrick.ui.MCPService")
        let search = MCPToolSearchRequest(principal: .system, query: "script")
        let data = try MCPServiceXPCCodec.encodeToolSearchRequest(search)
        let decoded = try MCPServiceXPCCodec.decodeToolSearchRequest(data)
        #expect(decoded.query == "script")
        #expect(decoded.principal == .system)
    }

    @Test func approvalDTORoundTrip() throws {
        let request = AgentApprovalRequestDTO(
            approvalID: "a1",
            turnID: "t1",
            sessionID: "s1",
            toolName: "script_exec",
            argumentsJSON: #"{"code":"print(1)"}"#,
            requiredFields: ["review"]
        )
        let data = try AgentServiceXPCCodec.encodeApprovalRequest(request)
        let decoded = try AgentServiceXPCCodec.decodeApprovalRequest(data)
        #expect(decoded.toolName == "script_exec")
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

    @Test func pluginSecretResolverReadsKeychainOnly() throws {
        try PluginSecretKeychain.save(
            pluginID: "test-plugin-keychain",
            fieldID: "bot_token",
            value: "test-token"
        )
        defer {
            PluginSecretKeychain.deleteForTesting(
                pluginID: "test-plugin-keychain",
                fieldID: "bot_token"
            )
        }
        #expect(
            PluginSecretResolver.resolve(pluginID: "test-plugin-keychain", fieldID: "bot_token") == "test-token"
        )
    }

    @Test func pluginSecretDevelopmentSourceReadsDotEnvInDevelopmentMode() throws {
        PluginSecretKeychain.deleteForTesting(
            pluginID: "test-plugin-dotenv",
            fieldID: "bot_token"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resources = root.appendingPathComponent("ui/ui/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try DotEnvTestFixtures.fileBody(extraLines: ["PLUGIN_TEST_PLUGIN_DOTENV_BOT_TOKEN=dev-token"]).write(
            to: resources.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )

        let resolved = PluginSecretDevelopmentSource.resolve(
            pluginID: "test-plugin-dotenv",
            fieldID: "bot_token",
            environment: [:],
            bundleURL: root,
            currentDirectoryURL: root
        )
        #expect(resolved == "dev-token")
    }

    @Test func pluginSecretDevelopmentSourceReadsInlineEnvironment() {
        let resolved = PluginSecretDevelopmentSource.resolve(
            pluginID: "slack-connection",
            fieldID: "bot_token",
            environment: [
                DotEnvReader.secretModeKey: DotEnvReader.SecretSourceMode.dotenv.rawValue,
                "SLACK_BOT_KEY": "xoxb-dev-token",
            ],
            bundleURL: URL(fileURLWithPath: "/tmp", isDirectory: true),
            currentDirectoryURL: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )
        #expect(resolved == "xoxb-dev-token")
    }

    @Test func pluginSecretDevelopmentSourceReadsSlackBotKeyForFactoryConnectorID() {
        let resolved = PluginSecretDevelopmentSource.resolve(
            pluginID: "slack-connector",
            fieldID: "bot_token",
            environment: [
                DotEnvReader.secretModeKey: DotEnvReader.SecretSourceMode.dotenv.rawValue,
                "SLACK_BOT_KEY": "xoxb-dev-token",
            ],
            bundleURL: URL(fileURLWithPath: "/tmp", isDirectory: true),
            currentDirectoryURL: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )
        #expect(resolved == "xoxb-dev-token")
    }

    @Test func pluginSecretDevelopmentSourceDoesNotApplySlackBotKeyToUnrelatedPlugin() {
        let resolved = PluginSecretDevelopmentSource.resolve(
            pluginID: "weather-tool",
            fieldID: "bot_token",
            environment: [
                DotEnvReader.secretModeKey: DotEnvReader.SecretSourceMode.dotenv.rawValue,
                "SLACK_BOT_KEY": "xoxb-dev-token",
            ],
            bundleURL: URL(fileURLWithPath: "/tmp", isDirectory: true),
            currentDirectoryURL: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )
        #expect(resolved == nil)
    }

    @Test func slackConnectorFallsBackToBotTokenWhenManifestOmitsSecrets() {
        let json = """
        {"$schema":"https://example.invalid/agent-plugin.json","name":"slack-connector","version":"1.0.0",\
        "extensions":{"app.derrick":{"entrypoint":"./app.derrick/plugin.go","role":"connector","messaging_ops":["sync_threads"]}}}
        """
        let descriptors = PluginSecretField.resolvedDescriptors(
            pluginID: "slack-connector",
            fromManifestJSON: json
        )
        #expect(descriptors.map(\.id) == ["bot_token"])
        #expect(
            PluginSecretField.resolvedDescriptors(pluginID: "weather-tool", fromManifestJSON: json).isEmpty
        )
    }

    @Test func pluginSecretResolverIgnoresDotEnvWhenNotInDevelopmentMode() throws {
        PluginSecretKeychain.deleteForTesting(
            pluginID: "test-plugin-dotenv",
            fieldID: "bot_token"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resources = root.appendingPathComponent("ui/ui/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try """
        UI_SECRET_MODE=keychain
        IS_DEBUG=false
        PLUGIN_TEST_PLUGIN_DOTENV_BOT_TOKEN=ignored
        """.write(
            to: resources.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )

        let resolved = PluginSecretDevelopmentSource.resolve(
            pluginID: "test-plugin-dotenv",
            fieldID: "bot_token",
            environment: ["IS_DEBUG": "false"],
            bundleURL: root,
            currentDirectoryURL: root
        )
        #expect(resolved == nil)
    }

    @Test func dotenvReaderFindsRepositoryRelativePath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resources = root.appendingPathComponent("ui/ui/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try DotEnvTestFixtures.fileBody(extraLines: ["GEMINI_API_KEY=test"]).write(
            to: resources.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )

        let value = DotEnvReader.firstValue(
            for: ["GEMINI_API_KEY"],
            environment: [:],
            bundleURL: root,
            currentDirectoryURL: root
        )
        #expect(value == "test")
    }

    @Test func hostUIApplicationURLFromEmbeddedLoginItemDaemon() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let host = root.appendingPathComponent("Derrick.app", isDirectory: true)
        let daemon = host
            .appendingPathComponent("Contents/Library/LoginItems/JobKeepAlive.app", isDirectory: true)
        let hostInfo = host.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: hostInfo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>\(DerrickAppSupport.hostAppBundleIdentifier)</string>
        </dict></plist>
        """.write(to: hostInfo, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: daemon, withIntermediateDirectories: true)

        let resolved = DerrickAppSupport.hostUIApplicationURL(bundleURL: daemon)
        #expect(resolved?.standardizedFileURL.path == host.standardizedFileURL.path)
    }

    @Test func pluginSecretKeychainAccountIsStable() {
        #expect(
            PluginSecretKeychain.account(pluginID: "slack-connection", fieldID: "password")
                == "plugin-secret:slack-connection/password"
        )
        #expect(PluginCredentialPrompt.toolName == "plugin.credentials")
    }

    @Test func pluginSecretKeychainMigratesRetiredPluginFields() throws {
        let sourceID = "test-migrate-source-\(UUID().uuidString)"
        let destID = "test-migrate-dest-\(UUID().uuidString)"
        defer {
            PluginSecretKeychain.deleteForTesting(pluginID: sourceID, fieldID: "bot_token")
            PluginSecretKeychain.deleteForTesting(pluginID: destID, fieldID: "bot_token")
        }
        try PluginSecretKeychain.save(
            pluginID: sourceID,
            fieldID: "bot_token",
            value: "legacy-token"
        )
        let fields = [PluginSecretDescriptor(id: "bot_token", label: "Bot token", kind: "token")]
        PluginSecretKeychain.migrateStoredFields(
            from: sourceID,
            to: destID,
            fields: fields
        )
        #expect(PluginSecretKeychain.hasStoredValue(pluginID: destID, fieldID: "bot_token"))
        #expect(try PluginSecretKeychain.load(pluginID: destID, fieldID: "bot_token") == "legacy-token")
    }

    @Test func pluginSecretKeychainSharedStoreIsReadableAfterSave() throws {
        let pluginID = "test-shared-store-\(UUID().uuidString)"
        defer {
            PluginSecretKeychain.deleteForTesting(pluginID: pluginID, fieldID: "bot_token")
        }
        try PluginSecretKeychain.save(pluginID: pluginID, fieldID: "bot_token", value: "shared-token")
        #expect(try PluginSecretKeychain.loadFromKeychain(pluginID: pluginID, fieldID: "bot_token") == "shared-token")
        #expect(PluginSecretKeychain.hasKeychainValue(pluginID: pluginID, fieldID: "bot_token"))
    }

    @Test func pluginSecretKeychainMissingKeychainIDsIgnoresDotenv() throws {
        let pluginID = "test-keychain-missing-\(UUID().uuidString)"
        defer {
            PluginSecretKeychain.deleteForTesting(pluginID: pluginID, fieldID: "bot_token")
        }
        let fields = [PluginSecretDescriptor(id: "bot_token", label: "Bot token", kind: "token")]
        #expect(!PluginSecretKeychain.missingKeychainIDs(pluginID: pluginID, fields: fields).isEmpty)
        try PluginSecretKeychain.save(pluginID: pluginID, fieldID: "bot_token", value: "stored-token")
        #expect(PluginSecretKeychain.missingKeychainIDs(pluginID: pluginID, fields: fields).isEmpty)
        #expect(PluginSecretKeychain.hasKeychainValue(pluginID: pluginID, fieldID: "bot_token"))
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

    @Test func messageSigningSurvivesJSONDateRoundTrip() throws {
        let key = ServiceMessageSigning.developmentKey(seed: "helloworld")
        var msg = ServiceMessage(
            from: .ui,
            to: .agent,
            type: .peerHandoff,
            principal: .system,
            correlationId: "installMCPPeer",
            payloadJSON: Data(#"{"kind":"installMCPPeer"}"#.utf8)
        )
        ServiceMessageSigning.sign(&msg, key: key)
        let data = try JSONEncoder.service.encode(msg)
        let decoded = try JSONDecoder.service.decode(ServiceMessage.self, from: data)
        #expect(ServiceMessageSigning.verify(decoded, key: key))
        let dto = try MCPServiceXPCCodec.decodeSignedPeerHandoffAuth(
            data,
            expectedTo: .agent,
            expectedKind: .installMCPPeer,
            key: key
        )
        #expect(dto.kind == .installMCPPeer)
    }

    @Test func signedToolCallEnvelopeRoundTrip() throws {
        let key = ServiceMessageSigning.developmentKey(seed: "test-messages-secret")
        let request = MCPToolCallRequest(
            principal: .agent(sessionID: "s1", agentID: "ui"),
            toolName: "script_exec",
            argumentsJSON: #"{"script":"print(1)"}"#,
            helperAPIKey: "sk-test"
        )
        let data = try MCPServiceXPCCodec.encodeSignedToolCallRequest(request, key: key)
        let decoded = try MCPServiceXPCCodec.decodeSignedToolCallRequest(data, key: key)
        #expect(decoded.toolName == "script_exec")
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

    @Test func jobStepSpecsEncode() throws {
        let tool = try CreateJobStepSpec.runTool(
            JobRunToolPayload(toolName: "script_exec", argumentsJSON: #"{"mode":"readonly"}"#)
        )
        #expect(tool.kind == .runTool)
        let wake = try CreateJobStepSpec.wakeAgent(JobWakeAgentPayload(prompt: "hello"))
        #expect(wake.kind == .wakeAgent)
        let req = CreateJobRequest(
            principal: .system,
            source: .webhook,
            runAt: nil,
            steps: [tool, wake]
        )
        #expect(req.steps.count == 2)
        let data = try JobServiceXPCCodec.encodeCreateJobRequest(req)
        let decoded = try JobServiceXPCCodec.decodeCreateJobRequest(data)
        #expect(decoded.source == .webhook)
    }

    @Test func jobOrderBuilderOneShotAndAbsoluteTime() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let input = JobCreateOrderInput(
            runAfterSeconds: 3,
            toolName: "script_exec",
            toolArgumentsJSON: #"{"script":"print(1)","mode":"readonly"}"#,
            wakeAfter: true,
            wakePrompt: "Announce the number from the tool result."
        )
        let req = try JobOrderBuilder.createJobRequest(
            from: input,
            principal: .agent(sessionID: "s1", agentID: "ui"),
            sessionID: "s1",
            agentID: "ui",
            now: now
        )
        #expect(req.steps.count == 1)
        #expect(req.steps[0].kind == .runToolThenWake)
        #expect(req.runAt == now.addingTimeInterval(3))
        #expect(req.source == .agent)

        let at3pm = JobOrderBuilder.parseRunAtString("15:00", now: now)!
        let cal = Calendar.current
        #expect(cal.component(.hour, from: at3pm) == 15)

        #expect(throws: JobOrderBuilderError.toolNotAllowed("shell_exec")) {
            _ = try JobOrderBuilder.createJobRequest(
                from: JobCreateOrderInput(
                    toolName: "shell_exec",
                    toolArgumentsJSON: #"{"x":1}"#,
                    wakeAfter: false
                ),
                principal: .system,
                sessionID: nil,
                agentID: nil,
                now: now
            )
        }

        let crawl = try JobOrderBuilder.createJobRequest(
            from: JobCreateOrderInput(
                toolName: "web.crawl",
                toolArgumentsJSON: #"{"start_url":"https://example.com","goal":"read the page"}"#,
                wakeAfter: true,
                wakePrompt: "Present the crawl result to the user."
            ),
            principal: .agent(sessionID: "s1", agentID: "ui"),
            sessionID: "s1",
            agentID: "ui",
            now: now
        )
        #expect(crawl.steps[0].kind == .runToolThenWake)
    }

    @Test func jobOrderBuilderScheduleInterval() throws {
        let input = JobScheduleOrderInput(
            name: "hourly",
            recurrenceKind: .interval,
            intervalSeconds: 3600,
            runAfterSeconds: 0,
            toolName: "script_exec",
            toolArgumentsJSON: #"{"script":"print(1)","mode":"readonly"}"#,
            wakeAfter: false
        )
        let req = try JobOrderBuilder.createScheduleRequest(
            from: input,
            principal: .system,
            sessionID: nil,
            agentID: nil
        )
        #expect(req.recurrence.kind == .interval)
        #expect(req.recurrence.intervalSeconds == 3600)
        #expect(req.steps[0].kind == .runTool)
    }

    @Test func jobFailureReasonLastAttemptMessage() {
        let msg = JobFailureReason.interruptedDeviceUnavailable.lastAttemptMessage()
        #expect(msg.hasPrefix("Last attempt failed due to:"))
        #expect(msg.contains("sleep") || msg.contains("JobService stopped"))
        let withDetail = JobFailureReason.stepFailed.lastAttemptMessage(detail: "tool denied")
        #expect(withDetail.contains("tool denied"))
        let late = JobStatusDetail.startedLate(
            scheduledAt: Date(timeIntervalSince1970: 0),
            startedAt: Date(timeIntervalSince1970: 3600)
        )
        #expect(late.contains("late"))
        #expect(late.contains("asleep") || late.contains("not running"))
    }

    @Test func jobFailureDisplayExtractsTechnicalDetail() {
        let detail = JobFailureDisplay.technicalDetail(
            from: "Last attempt failed due to: a job step failed — something went wrong"
        )
        #expect(detail == "something went wrong")
    }

    @Test func jobFailureDisplayReplacesGenericDetail() {
        let detail = JobFailureDisplay.userFacingDetail(
            from: "something went wrong",
            failureCode: JobFailureReason.stepFailed.rawValue
        )
        #expect(detail?.contains("No specific error details") == true)
        #expect(detail?.contains("something went wrong") == false)
    }

    @Test func jobFailureDisplayPreservesSubstantiveDetail() {
        let detail = JobFailureDisplay.userFacingDetail(
            from: "ModuleNotFoundError: No module named 'requests'",
            failureCode: JobFailureReason.stepFailed.rawValue
        )
        #expect(detail == "ModuleNotFoundError: No module named 'requests'")
    }

    @Test func jobFailureDisplaySkipsFooterForSuccessfulJob() {
        let text = JobFailureDisplay.composePresentation(
            responseText: "Apple.com is currently highlighting the latest iPhone lineup.",
            failureDetail: nil,
            failureCode: nil
        )
        #expect(!text.contains("What went wrong"))
        #expect(text == "Apple.com is currently highlighting the latest iPhone lineup.")
    }

    @Test func jobFailureDisplaySkipsRedundantFooterWhenSummaryExplainsFailure() {
        let text = JobFailureDisplay.composePresentation(
            responseText: "The scheduled script failed during execution.",
            failureDetail: "something went wrong",
            failureCode: JobFailureReason.stepFailed.rawValue
        )
        #expect(!text.contains("What went wrong"))
        #expect(!text.contains("something went wrong"))
    }

    @Test func jobFailureDisplayAppendsSubstantiveFooter() {
        let text = JobFailureDisplay.composePresentation(
            responseText: "The job failed with no details.",
            failureDetail: "exit code 1: Permission denied",
            failureCode: JobFailureReason.stepFailed.rawValue
        )
        #expect(text.contains("What went wrong"))
        #expect(text.contains("Permission denied"))
    }

    @Test func derrickNotificationLaunchDetectsPendingPresentationIntent() {
        guard appGroupCrossProcessStorageIsAvailable() else { return }
        let id = "FE1AB9C3-C51F-4A8D-AB94-0C01E9357D19"
        DerrickJobResultPresentationWake.post(resultID: id)
        defer { _ = DerrickJobResultPresentationWake.takePendingResultID() }
        #expect(DerrickNotificationLaunch.hasJobResultPresentationIntent([]))
        #expect(!DerrickNotificationLaunch.isJobResultPresentationLaunch([]))
    }

    @Test func messagingInboundNotificationCopyHidesOpaqueVendorActorIDs() {
        #expect(MessagingInboundNotificationCopy.isOpaqueVendorActorID("U07FKG8DV19"))
        #expect(!MessagingInboundNotificationCopy.isOpaqueVendorActorID("alice"))
        #expect(
            MessagingInboundNotificationCopy.previewBody(
                sender: "U07FKG8DV19",
                body: "bt4",
                isReply: true
            ) == "bt4"
        )
        #expect(
            MessagingInboundNotificationCopy.previewBody(
                sender: "alice",
                body: "hello"
            ) == "alice: hello"
        )
    }

    @Test func derrickNotificationLaunchParsesMessagingConversationArgv() {
        let args = [
            "derrick",
            DerrickNotificationLaunch.showMessagingConversationArgument,
            "slack-bot",
            "thread-1",
        ]
        let payload = DerrickNotificationLaunch.messagingConversationToPresent(args)
        #expect(payload?.pluginID == "slack-bot")
        #expect(payload?.threadID == "thread-1")
        #expect(DerrickNotificationLaunch.hasMessagingConversationPresentationIntent(args))
        #expect(!DerrickNotificationLaunch.hasJobResultPresentationIntent(args))
    }

    @Test func derrickMessagingConversationWakeRoundTripsPendingPayload() {
        guard appGroupCrossProcessStorageIsAvailable() else { return }
        _ = DerrickMessagingConversationPresentationWake.takePending()
        DerrickMessagingConversationPresentationWake.post(pluginID: "slack-bot", threadID: "thread-1")
        defer { _ = DerrickMessagingConversationPresentationWake.takePending() }
        #expect(DerrickNotificationLaunch.hasMessagingConversationPresentationIntent([]))
        let payload = DerrickMessagingConversationPresentationWake.peekPending()
        #expect(payload?.pluginID == "slack-bot")
        #expect(payload?.threadID == "thread-1")
        let taken = DerrickMessagingConversationPresentationWake.takePending()
        #expect(taken?.threadID == "thread-1")
        #expect(DerrickMessagingConversationPresentationWake.peekPending() == nil)
    }

    @Test func derrickUISessionPresenceTracksLivePID() {
        guard appGroupCrossProcessStorageIsAvailable() else { return }
        DerrickUISessionPresence.clearInteractiveSession()
        defer { DerrickUISessionPresence.clearInteractiveSession() }
        #expect(!DerrickUISessionPresence.isInteractiveSessionActive())
        DerrickUISessionPresence.markInteractiveSessionActive()
        #expect(DerrickUISessionPresence.isInteractiveSessionActive(excludingPID: -1))
        #expect(!DerrickUISessionPresence.isInteractiveSessionActive())
    }

    @Test func derrickMessagingForegroundPresenceSuppressesViewedConnector() {
        guard appGroupCrossProcessStorageIsAvailable() else { return }
        DerrickMessagingForegroundPresence.clear()
        defer { DerrickMessagingForegroundPresence.clear() }
        DerrickMessagingForegroundPresence.sync(
            isMessagingWorkspace: true,
            pluginID: "slack-connector-1",
            isFrontmost: true
        )
        #expect(
            DerrickMessagingForegroundPresence.pluginIDForSuppressedOSNotifications(excludingPID: -1)
                == "slack-connector-1"
        )
        DerrickMessagingForegroundPresence.sync(
            isMessagingWorkspace: true,
            pluginID: "slack-connector-1",
            isFrontmost: false
        )
        #expect(
            DerrickMessagingForegroundPresence.pluginIDForSuppressedOSNotifications(excludingPID: -1) == nil
        )
    }

    @Test func derrickDaemonHygieneRestartAfterOrphanEviction() {
        #expect(
            DerrickDaemonHygiene.shouldRestartDaemonAfterReconcile(
                evictedAny: true,
                hasHealthyExpectedDaemon: false
            )
        )
        #expect(
            !DerrickDaemonHygiene.shouldRestartDaemonAfterReconcile(
                evictedAny: false,
                hasHealthyExpectedDaemon: true
            )
        )
        #expect(
            !DerrickDaemonHygiene.shouldRestartDaemonAfterReconcile(
                evictedAny: false,
                hasHealthyExpectedDaemon: true,
                launchdJobLoaded: false
            )
        )
        #expect(
            DerrickDaemonHygiene.shouldRestartDaemonAfterReconcile(
                evictedAny: false,
                hasHealthyExpectedDaemon: true,
                healthyExpectedDaemonCount: 3
            )
        )
        #expect(
            !DerrickDaemonHygiene.shouldRestartDaemonAfterReconcile(
                evictedAny: false,
                hasHealthyExpectedDaemon: true,
                launchdJobLoaded: true,
                healthyExpectedDaemonCount: 1
            )
        )
    }

    @Test func derrickDaemonHygieneEvictsDuplicateExpectedDaemons() {
        let expected = "/tmp/Derrick.app/Contents/Library/LoginItems/JobKeepAlive.app/Contents/MacOS/JobKeepAlive"
        let evict = DerrickDaemonHygiene.duplicateExpectedDaemonPIDsToEvict(
            expectedExecutablePath: expected,
            processes: [
                (pid: 10, executablePath: expected, startDate: Date(timeIntervalSince1970: 1)),
                (pid: 11, executablePath: expected, startDate: Date(timeIntervalSince1970: 3)),
                (pid: 12, executablePath: expected, startDate: Date(timeIntervalSince1970: 2)),
            ]
        )
        #expect(Set(evict) == [10, 12])
    }

    @Test func derrickDaemonHygieneDetectsStaleLaunchAgentProgramAfterProductRename() {
        let expected = "/Users/me/DerivedData/.../Debug/Derrick.app/Contents/Library/LoginItems/JobKeepAlive.app/Contents/MacOS/JobKeepAlive"
        #expect(
            DerrickDaemonHygiene.isRegisteredDaemonProgramStale(
                registeredProgramPath: "/Users/me/DerivedData/.../Debug/ui.app/Contents/Library/LoginItems/JobKeepAlive.app/Contents/MacOS/JobKeepAlive",
                expectedExecutablePath: expected
            )
        )
        #expect(
            !DerrickDaemonHygiene.isRegisteredDaemonProgramStale(
                registeredProgramPath: expected,
                expectedExecutablePath: expected
            )
        )
        #expect(
            DerrickDaemonHygiene.isRegisteredDaemonProgramStale(
                registeredProgramPath: nil,
                expectedExecutablePath: expected
            )
        )
    }

    @Test func daemonSessionLaunchAgentStaysOutOfLaunchAgents() {
        let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
        let url = DerrickAppSupport.daemonSessionLaunchAgentPlistURL(homeDirectory: home)
        #expect(!url.path.contains("/Library/LaunchAgents/"))
        #expect(url.path.contains("/Library/Application Support/Derrick/"))
        #expect(url.lastPathComponent == "derrick.ui.Daemon.session.plist")
        #expect(DerrickServiceID.daemonSessionLaunchdLabel == "derrick.ui.Daemon.session")
        #expect(DerrickServiceID.daemonSessionLaunchdLabel != DerrickServiceID.daemon.rawValue)
        #expect(DerrickServiceID.daemon.machServiceName == "\(DerrickServiceID.appGroupID).daemon")
        #expect(DerrickServiceID.demandStartLaunchdLabels.count == 3)
        #expect(Set(DerrickServiceID.demandStartLaunchdLabels) == [
            DerrickServiceID.daemon.rawValue,
            DerrickServiceID.daemonSessionLaunchdLabel,
            DerrickServiceID.jobKeepAlive.rawValue,
        ])
        #expect(DerrickServiceID.demandStartLaunchdLabels.allSatisfy { !$0.contains("application.") })
    }

    @Test func smAppSpawnHandoffDetectsRunningBoardDaemonJob() {
        #expect(
            DerrickDaemonHygiene.shouldHandoffSMAppSpawnToSessionAgent(
                xpcServiceName: "application.derrick.ui.Daemon.1.2.UUID"
            )
        )
        #expect(
            !DerrickDaemonHygiene.shouldHandoffSMAppSpawnToSessionAgent(xpcServiceName: nil)
        )
        #expect(
            !DerrickDaemonHygiene.shouldHandoffSMAppSpawnToSessionAgent(
                xpcServiceName: DerrickServiceID.daemon.rawValue
            )
        )
        #expect(
            !DerrickDaemonHygiene.shouldHandoffSMAppSpawnToSessionAgent(
                xpcServiceName: DerrickServiceID.daemonSessionLaunchdLabel
            )
        )
    }

    @Test func derrickDaemonHygieneDetectsOrphanPath() {
        let host = "/Users/me/DerivedData/.../Debug/Derrick.app"
        let orphan = "/Users/me/DerivedData/.../Debug/JobKeepAlive.app/Contents/MacOS/JobKeepAlive"
        let reason = DerrickDaemonHygiene.evictionReason(
            executablePath: orphan,
            processStartDate: Date(),
            hostAppBundlePath: host,
            expectedExecutablePath: "\(host)/Contents/Library/LoginItems/JobKeepAlive.app/Contents/MacOS/JobKeepAlive",
            expectedExecutableModificationDate: Date()
        )
        #expect(reason == .orphanPath)
    }

    @Test func derrickDaemonHygieneDetectsStaleBuild() {
        let host = "/Users/me/DerivedData/.../Debug/Derrick.app"
        let embedded = "\(host)/Contents/Library/LoginItems/JobKeepAlive.app/Contents/MacOS/JobKeepAlive"
        let started = Date(timeIntervalSince1970: 1_000)
        let rebuilt = Date(timeIntervalSince1970: 2_000)
        let reason = DerrickDaemonHygiene.evictionReason(
            executablePath: embedded,
            processStartDate: started,
            hostAppBundlePath: host,
            expectedExecutablePath: embedded,
            expectedExecutableModificationDate: rebuilt
        )
        #expect(reason == nil)
    }

    @Test func derrickDaemonHygieneStaleWhenAcceptedMtimeDiffers() {
        let host = "/Users/me/DerivedData/.../Debug/Derrick.app"
        let embedded = "\(host)/Contents/Library/LoginItems/JobKeepAlive.app/Contents/MacOS/JobKeepAlive"
        let reason = DerrickDaemonHygiene.evictionReasonUsingAcceptedBinaryMtime(
            executablePath: embedded,
            processStartDate: nil,
            hostAppBundlePath: host,
            expectedExecutablePath: embedded,
            expectedExecutableModificationDate: Date(timeIntervalSince1970: 2_000),
            lastAcceptedExecutableModificationDate: Date(timeIntervalSince1970: 1_000)
        )
        #expect(reason == nil)
    }

    @Test func derrickDaemonHygieneAcceptsFirstObserveWithoutStartDate() {
        let host = "/Users/me/DerivedData/.../Debug/Derrick.app"
        let embedded = "\(host)/Contents/Library/LoginItems/JobKeepAlive.app/Contents/MacOS/JobKeepAlive"
        let reason = DerrickDaemonHygiene.evictionReasonUsingAcceptedBinaryMtime(
            executablePath: embedded,
            processStartDate: nil,
            hostAppBundlePath: host,
            expectedExecutablePath: embedded,
            expectedExecutableModificationDate: Date(timeIntervalSince1970: 2_000),
            lastAcceptedExecutableModificationDate: nil
        )
        #expect(reason == nil)
    }

    @Test func daemonBinaryIdentityFingerprintsDifferWhenStatChanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("JobKeepAlive")
        try Data("v1".utf8).write(to: file)
        let first = DerrickDaemonBinaryIdentity.snapshot(atPath: file.path)
        #expect(first != nil)
        try Data("v2-longer".utf8).write(to: file)
        let second = DerrickDaemonBinaryIdentity.snapshot(atPath: file.path)
        #expect(second != nil)
        #expect(first != second)
        #expect(first?.fingerprint != second?.fingerprint)
    }

    @Test func shouldRetireConnectedDaemonOnFingerprintOrRuntimeMismatch() {
        #expect(
            DerrickDaemonHygiene.shouldRetireConnectedDaemon(
                reportedFingerprint: "a",
                expectedFingerprint: "a",
                reportedGuestRuntime: DerrickGuestRuntime.swiftPluginDockerImage,
                expectedGuestRuntime: DerrickGuestRuntime.guestDockerImage
            )
        )
        #expect(
            !DerrickDaemonHygiene.shouldRetireConnectedDaemon(
                reportedFingerprint: "a",
                expectedFingerprint: "a",
                reportedGuestRuntime: DerrickGuestRuntime.guestDockerImage,
                expectedGuestRuntime: DerrickGuestRuntime.guestDockerImage
            )
        )
        #expect(
            DerrickDaemonHygiene.shouldRetireConnectedDaemon(
                reportedFingerprint: "old",
                expectedFingerprint: "new",
                reportedGuestRuntime: DerrickGuestRuntime.swiftPluginDockerImage,
                expectedGuestRuntime: DerrickGuestRuntime.guestDockerImage
            )
        )
        #expect(
            DerrickDaemonHygiene.shouldRetireConnectedDaemon(
                reportedFingerprint: "a",
                expectedFingerprint: "a",
                reportedGuestRuntime: "stale-guest:old",
                expectedGuestRuntime: DerrickGuestRuntime.guestDockerImage
            )
        )
        #expect(
            DerrickDaemonHygiene.shouldRetireConnectedDaemon(
                reportedFingerprint: nil,
                expectedFingerprint: "a",
                reportedGuestRuntime: DerrickGuestRuntime.swiftPluginDockerImage,
                expectedGuestRuntime: DerrickGuestRuntime.guestDockerImage
            )
        )
        #expect(
            DerrickDaemonHygiene.shouldRetireConnectedDaemon(
                reportedFingerprint: "a",
                expectedFingerprint: nil,
                reportedGuestRuntime: DerrickGuestRuntime.swiftPluginDockerImage,
                expectedGuestRuntime: DerrickGuestRuntime.guestDockerImage
            )
        )
    }

    @Test func derrickDaemonHygieneKeepsFreshEmbeddedDaemon() {
        let host = "/Users/me/DerivedData/.../Debug/Derrick.app"
        let embedded = "\(host)/Contents/Library/LoginItems/JobKeepAlive.app/Contents/MacOS/JobKeepAlive"
        let started = Date(timeIntervalSince1970: 2_000)
        let built = Date(timeIntervalSince1970: 1_000)
        let reason = DerrickDaemonHygiene.evictionReason(
            executablePath: embedded,
            processStartDate: started,
            hostAppBundlePath: host,
            expectedExecutablePath: embedded,
            expectedExecutableModificationDate: built
        )
        #expect(reason == nil)
    }

    @Test func normalizeScriptArgumentsCoercesInvalidMode() {
        let normalized = JobOrderBuilder.normalizeScriptArgumentsJSONLegacy(
            #"{"mode":"run","script":"print(1)"}"#
        )
        #expect(normalized.contains(#""mode":"readonly"#))
    }

    @Test func jobFailureUserReportPromptIncludesFailureContext() {
        let prompt = JobFailureUserReportPrompt.failureWakePrompt(
            originalWakePrompt: "Summarize the crawl result.",
            failureMessage: "Last attempt failed due to: a job step failed — timeout",
            failureCode: "stepFailed"
        )
        #expect(prompt.contains("Summarize the crawl result."))
        #expect(prompt.contains("[job failed]"))
        #expect(prompt.contains("stepFailed"))
        #expect(prompt.contains("timeout"))
        #expect(prompt.contains("plain prose"))
        #expect(prompt.contains("Do NOT include"))
    }

    @Test func jobFailureUserReportPromptSilentOnSuccess() {
        let prompt = JobFailureUserReportPrompt.failureWakePrompt(
            originalWakePrompt: "",
            failureMessage: "Last attempt failed due to: a job step failed",
            failureCode: "stepFailed",
            silentOnSuccess: true
        )
        #expect(prompt.contains("wake_after=false"))
        #expect(prompt.contains("[job failed]"))
    }

    @Test func resolveFailureWakePayloadFromRunToolOnlyJob() throws {
        let toolJSON = try JSONEncoder.service.encode(
            JobRunToolPayload(
                toolName: "script_exec",
                argumentsJSON: #"{"mode":"readonly","script":"print(1)"}"#,
                helperAPIKey: "test-key",
                helperReviewerModelJSON: #"{"openai":{"_0":"gpt-5.6-luna"}}"#
            )
        )
        let principal = try JSONEncoder.service.encode(ServicePrincipal.agent(sessionID: "chat-1", agentID: "main"))
        let resolved = JobWakeContext.resolveFailureWakePayload(
            steps: [(.runTool, String(data: toolJSON, encoding: .utf8)!)],
            failedStepPayloadJSON: String(data: toolJSON, encoding: .utf8),
            failedStepKind: .runTool,
            jobID: "job-1",
            principalJSON: String(data: principal, encoding: .utf8)!
        )
        #expect(resolved?.silentOnSuccess == true)
        #expect(resolved?.wake.apiKey == "test-key")
        #expect(resolved?.wake.parentSessionID == "chat-1")
        #expect(resolved?.wake.jobID == "job-1")
    }

    @Test func scheduleTimingAndSignedCRUD() throws {
        let fired = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(JobScheduleTiming.nextFireDate(after: fired, recurrence: .once) == nil)
        let next = JobScheduleTiming.nextFireDate(after: fired, recurrence: .every(hours: 1))
        #expect(next == fired.addingTimeInterval(3600))

        let key = ServiceMessageSigning.developmentKey(seed: "test-messages-secret")
        let step = try CreateJobStepSpec.wakeAgent(JobWakeAgentPayload(prompt: "heartbeat"))
        let create = CreateScheduleRequest(
            name: "hourly-wake",
            principal: .system,
            source: .ui,
            recurrence: .every(hours: 1),
            steps: [step],
            nextFireAt: fired,
            enabled: true
        )
        let data = try JobServiceXPCCodec.encodeSignedCreateSchedule(create, from: .ui, key: key)
        let decoded = try JobServiceXPCCodec.decodeSignedCreateSchedule(data, key: key)
        #expect(decoded.name == "hourly-wake")
        #expect(decoded.recurrence.kind == .interval)
        #expect(decoded.source == .ui)

        let listData = try JobServiceXPCCodec.encodeSignedListSchedules(
            ListSchedulesRequest(limit: 10, enabledOnly: true),
            from: .agent,
            key: key
        )
        let listReq = try JobServiceXPCCodec.decodeSignedListSchedules(listData, key: key)
        #expect(listReq.enabledOnly == true)
        #expect(listReq.limit == 10)
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

    @Test func containerLifecyclePolicyDefaults() {
        let policy = ContainerLifecyclePolicy.derrickDefault
        #expect(policy.maxNetworkContainers == 2)
        #expect(policy.maxOfflineContainers == 1)
        #expect(policy.maxFileExtractContainers == 1)
        #expect(policy.warmStandbyCount == 0)
        #expect(policy.containerRunMaxTTLSeconds == 7 * 60)
        #expect(policy.destroyAfterEveryRun)
        #expect(policy.neverReusePostExecution)
    }

    @Test func derrickDockerRuntimeIdentityIsStable() {
        #expect(DerrickDockerRuntimeIdentity.labelAssignment == "app.derrick=runtime")
        #expect(DerrickDockerRuntimeIdentity.createLabelArguments == ["--label", "app.derrick=runtime"])
        #expect(DerrickDockerRuntimeIdentity.namePrefixes == [
            "derrick-web-crawler",
            "derrick-guest-runtime",
            "derrick-swift-runtime",
            "derrick-file-extractor",
        ])
        #expect(DerrickDockerRuntimeIdentity.isAllowedPsFilter("label=app.derrick=runtime"))
        #expect(DerrickDockerRuntimeIdentity.isAllowedPsFilter("name=derrick-guest-runtime"))
        #expect(!DerrickDockerRuntimeIdentity.isAllowedPsFilter("name=nginx"))
        #expect(
            DerrickDockerRuntimeIdentity.createHasRuntimeLabel(
                ["create"] + DerrickDockerRuntimeIdentity.createLabelArguments + [DockerWorkerRuntime.image]
            )
        )
        #expect(!DerrickDockerRuntimeIdentity.createHasRuntimeLabel(["create", "--name", "x", DockerWorkerRuntime.image]))
    }

    @Test func webCrawlerProductImageBuildUsesPackagesContext() {
        guard let root = DerrickRepositoryRoot.locate() else { return }
        let dockerfile = root
            .appendingPathComponent(DockerProductImagePolicy.webCrawlerDockerfileRelativePath)
            .path
        let packages = DockerProductImagePolicy.webCrawlerBuildContext(repoRoot: root).path
        #expect(
            DockerProductImagePolicy.isAllowedWebCrawlerBuild(
                dockerfilePath: dockerfile,
                imageTag: DockerProductImagePolicy.webCrawlerImage,
                contextPath: packages
            )
        )
        #expect(
            !DockerProductImagePolicy.isAllowedWebCrawlerBuild(
                dockerfilePath: dockerfile,
                imageTag: DockerProductImagePolicy.webCrawlerImage,
                contextPath: root.path
            )
        )
    }

    @Test func webCrawlerLinuxImageSourcesStayFoundationOnly() throws {
        guard let root = DerrickRepositoryRoot.locate() else { return }
        let folder = root
            .appendingPathComponent("packages/Structure/Sources/WebCrawler")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".swift") }
        #expect(!files.isEmpty)
        let banned = ["CryptoKit", "Security", "AppKit", "SwiftUI", "MCP"]
        for name in files {
            let text = try String(
                contentsOf: folder.appendingPathComponent(name),
                encoding: .utf8
            )
            #expect(text.contains("import Foundation"), "\(name) should import Foundation")
            for module in banned {
                #expect(
                    !text.contains("import \(module)"),
                    "\(name) must not import \(module); the Linux crawler image cannot compile Apple-only Structure"
                )
            }
        }
    }

    @Test func orchestrationLimitsDefaults() {
        let limits = OrchestrationLimits.default
        #expect(limits.maxDepth == 2)
        #expect(limits.maxChildrenPerAgent == 4)
        #expect(limits.maxConcurrentTurns == 4)
        #expect(limits.maxAgentsPerSession == 8)
        #expect(limits.maxMailboxDepth == 64)
        #expect(OrchestrationLimits.recommended == limits)
    }

    @Test func orchestrationLimitsClamp() {
        let high = OrchestrationLimits(
            maxDepth: 99,
            maxChildrenPerAgent: 99,
            maxConcurrentTurns: 99,
            maxAgentsPerSession: 99,
            maxMailboxDepth: 999
        ).clamped()
        #expect(high.maxDepth == OrchestrationLimits.absoluteMax.maxDepth)
        #expect(high.maxChildrenPerAgent == OrchestrationLimits.absoluteMax.maxChildrenPerAgent)
        #expect(high.maxConcurrentTurns == OrchestrationLimits.absoluteMax.maxConcurrentTurns)
        #expect(high.maxAgentsPerSession == OrchestrationLimits.absoluteMax.maxAgentsPerSession)
        #expect(high.maxMailboxDepth == OrchestrationLimits.absoluteMax.maxMailboxDepth)
    }

    @Test func containerLifecycleSettingsClampMinutes() {
        let low = ContainerLifecycleSettings(containerRunMaxTTLSeconds: 10).clamped()
        #expect(low.containerRunMaxTTLSeconds == ContainerLifecycleSettings.minimumTTLSeconds)

        let high = ContainerLifecycleSettings(containerRunMaxTTLSeconds: 9_999).clamped()
        #expect(high.containerRunMaxTTLSeconds == ContainerLifecycleSettings.maximumTTLSeconds)

        let fromMinutes = ContainerLifecycleSettings.fromMinutes(12)
        #expect(fromMinutes.containerRunMaxTTLSeconds == 12 * 60)
        #expect(fromMinutes.containerRunMaxTTLMinutes == 12)
    }

    @Test func effectorAdmissionAllowsWorkflowCrawl() {
        let context = ExecutionContextWire(
            sessionID: "s1",
            principal: .agent(sessionID: "s1", agentID: "a1"),
            workflow: WorkflowContextWire(workflowID: "w1", kind: .pluginFactoryCreate),
            capabilities: [.syncWebCrawl, .hostReviewRetry]
        )
        #expect(
            EffectorAdmissionPolicy.allowsSyncWebCrawl(
                context: context,
                principal: .agent(sessionID: "s1", agentID: "a1")
            )
        )
    }

    @Test func effectorAdmissionAllowsLiveChatWithoutContext() {
        #expect(
            EffectorAdmissionPolicy.allowsSyncWebCrawl(
                context: nil,
                principal: .agent(sessionID: "s1", agentID: "a1")
            )
        )
    }

    @Test func effectorAdmissionAllowsJobsWithoutContext() {
        #expect(
            EffectorAdmissionPolicy.allowsSyncWebCrawl(
                context: nil,
                principal: .job(jobID: "j1")
            )
        )
    }

    @Test func executionContextWireRoundTrip() throws {
        let context = ExecutionContextWire(
            sessionID: "s1",
            principal: .agent(sessionID: "s1", agentID: "ui"),
            turnID: "turn-1",
            agentID: "ui",
            workflow: WorkflowContextWire(
                workflowID: "wf-1",
                kind: .pluginFactoryCreate,
                stepKind: "crawl_vendor_docs"
            ),
            delivery: .liveChat,
            capabilities: [.syncWebCrawl, .hostReviewRetry]
        )
        let json = try context.encodedJSON()
        let decoded = try ExecutionContextWire.decodeJSON(json)
        #expect(decoded.sessionID == "s1")
        #expect(decoded.workflow?.workflowID == "wf-1")
        #expect(decoded.workflow?.kind == .pluginFactoryCreate)
        #expect(decoded.capabilities.contains(.syncWebCrawl))
        #expect(decoded.resolvedPrincipal.logLabel == context.resolvedPrincipal.logLabel)
    }

    @Test func workflowRuntimeXPCCodecRoundTrip() throws {
        let start = WorkflowStartRequest(
            kind: .pluginFactoryCreate,
            sessionID: "s1",
            turnID: "t1",
            agentID: "ui",
            inputJSON: "slack connector",
            principal: .agent(sessionID: "s1", agentID: "ui")
        )
        let decodedStart = try WorkflowRuntimeXPCCodec.decodeStart(
            try WorkflowRuntimeXPCCodec.encodeStart(start)
        )
        #expect(decodedStart == start)

        let handle = WorkflowHandleDTO(
            workflowID: "wf-1",
            kind: .pluginFactoryCreate,
            status: .running,
            deduplicated: false
        )
        #expect(
            try WorkflowRuntimeXPCCodec.decodeHandle(try WorkflowRuntimeXPCCodec.encodeHandle(handle)) == handle
        )
    }

    @Test func workflowChatProgressMapsFactoryStages() {
        #expect(
            WorkflowChatProgress.factoryProgressMessage(
                from: "[plugin_factory] attempt=2/3 draft_started"
            ) == "Waiting on the plugin builder (attempt 2 of 3). High thinking can take several minutes…"
        )
        #expect(
            WorkflowChatProgress.factoryProgressMessage(
                from: "[plugin_factory] builder_streaming"
            ) == "The plugin builder is writing the draft…"
        )
        #expect(
            WorkflowChatProgress.factoryProgressMessage(
                from: "[plugin_factory] review_started"
            ) == "Safety reviewer is checking the draft. This can take a few minutes…"
        )
        #expect(
            WorkflowChatProgress.factoryProgressMessage(
                from: "[plugin_factory] attempt=1/3 failed=The plugin builder model timed out."
            ) == "The plugin builder did not finish in time."
        )
        #expect(
            WorkflowChatProgress.shouldSurfaceWorkflowMessage(
                "[plugin_factory] attempt=1/3 draft_started"
            ) == false
        )
        #expect(
            WorkflowChatProgress.shouldSurfaceWorkflowMessage(
                "The direct test output exercises only poll_inbox."
            ) == false
        )
    }

    @Test func pluginFactoryCreateFailureMessageExplainsBuilderTimeout() {
        let presentation = PluginFactoryCreateFailureMessage.presentation("The request timed out.")
        #expect(presentation.summary.contains("plugin builder did not finish in time"))
        #expect(presentation.summary.contains("several minutes"))
        #expect(presentation.technicalDetail == "The request timed out.")
    }

    @Test func pluginFactoryCreateFailureMessageExplainsReviewerTimeout() {
        let presentation = PluginFactoryCreateFailureMessage.presentation(
            "The plugin safety reviewer model timed out."
        )
        #expect(presentation.summary.contains("safety reviewer did not finish in time"))
        #expect(presentation.technicalDetail?.contains("safety reviewer") == true)
    }

    @Test func pluginFactoryCreateFailureMessageSanitizesReviewDetail() {
        let raw = """
        The source appears to use the guest runtime envelope, stable de-duplication, channel-specific identifiers, and paginated Slack requests, but the supplied direct test does not cover the connector's required receive/sync operations.
        """
        let presentation = PluginFactoryCreateFailureMessage.presentation(raw)
        #expect(presentation.summary.contains("was not saved"))
        #expect(!presentation.summary.contains("guest runtime envelope"))
        #expect(presentation.summary.contains("safety review"))
        #expect(!presentation.summary.contains("Send only"))
        #expect(!presentation.summary.contains("Full sync"))
        #expect(presentation.technicalDetail == raw)
    }

    @Test func pluginFactoryCreateFailureMessageSanitizesDraftValidationDetail() {
        let raw = """
        Sort http_results by request_id and de-duplicate before lookup. Do not return the first matching entry from an unsorted loop.
        """
        let presentation = PluginFactoryCreateFailureMessage.presentation(raw)
        #expect(presentation.summary.contains("was not saved"))
        #expect(!presentation.summary.contains("http_results"))
        #expect(presentation.technicalDetail == raw)
    }

    @Test func pluginFactoryCreateFailureMessageExplainsMissingSavedConnector() {
        let raw = "Plugin factory did not return a saved connector."
        let presentation = PluginFactoryCreateFailureMessage.presentation(raw)
        #expect(presentation.summary.contains("was not saved"))
        #expect(presentation.technicalDetail == raw)
    }

    @Test func connectorManifestMessagingOpsDetectSendOnlyScope() {
        let sendOnly = """
        {"extensions":{"app.derrick":{"role":"connector","messaging_ops":["send_message"]}}}
        """
        let fullSync = """
        {"extensions":{"app.derrick":{"role":"connector","messaging_ops":["sync_threads","poll_inbox","send_message"]}}}
        """
        #expect(PluginFactoryValidationExpectations.isSendOnlyConnector(manifestJSON: sendOnly))
        #expect(!PluginFactoryValidationExpectations.isSendOnlyConnector(manifestJSON: fullSync))
        let sendAndReceive = """
        {"extensions":{"app.derrick":{"role":"connector","messaging_ops":["poll_inbox","send_message"]}}}
        """
        #expect(!PluginFactoryValidationExpectations.isSendOnlyConnector(manifestJSON: sendAndReceive))
    }

    @Test func pluginStudioFailureMapsToSkillFirstSteps() {
        #expect(PluginFactoryCreateInput.failureStep(forStage: "docs") == .build)
        #expect(PluginFactoryCreateInput.failureStep(forStage: "factory") == .build)
        #expect(PluginFactoryCreateInput.failureStep(forStage: "review") == .build)
        #expect(PluginFactoryCreateInput.failureStep(forStage: "description") == .skill)
        #expect(PluginFactoryCreateInput.failureStep(forStage: "type") == .skill)
        #expect(PluginFactoryCreateInput.failureStep(forStage: "name") == .skill)
        #expect(PluginFactoryCreateInput.failureStep(forStage: "auth") == .credentials)
        #expect(PluginFactoryCreateInput.failureStep(forStage: "discover") == .credentials)
        #expect(PluginFactoryCreateInput.failureStep(forStage: "goal") == .goal)
    }

    @Test func connectorWizardOffersFullSyncOnly() {
        #expect(PluginFactoryCreateInput.ConnectorScope.allCases == [.fullSync])
        #expect(PluginFactoryCreateInput.ConnectorScope.wizardCases == [.fullSync])
    }

    @Test func connectorWizardSelectsSlackOnly() {
        #expect(
            PluginFactoryCreateInput.ConnectorVendor.allCases.filter(\.isSelectableInWizard)
                == [.slack]
        )
        #expect(PluginFactoryCreateInput.ConnectorVendor.isEnabledMessagingPluginID("slack-connection"))
        #expect(PluginFactoryCreateInput.ConnectorVendor.isEnabledMessagingPluginID("Slack-Bot"))
        #expect(!PluginFactoryCreateInput.ConnectorVendor.isEnabledMessagingPluginID("telegram-bot"))
        #expect(!PluginFactoryCreateInput.ConnectorVendor.isEnabledMessagingPluginID("discord-connection"))
    }

    @Test func connectorBuildGoalUsesScopeAndReferenceBlueprint() {
        let input = PluginFactoryCreateInput.makeConnector(
            vendor: .slack,
            scope: .fullSync,
            userDescription: "Post alerts to #general."
        )
        let goal = input.connectorBuildGoal(crawlSummary: nil)
        #expect(goal.contains("Scope id: full_sync"))
        #expect(goal.contains("send_message"))
        #expect(goal.contains("sync_threads"))
        #expect(goal.contains("poll_inbox"))
        #expect(goal.contains("Host plugin id"))
        #expect(goal.contains("conversations.list") || goal.contains("vendor slack"))
        #expect(!goal.contains("must sync and send messages"))
        #expect(!goal.contains("Post alerts to #general"))
        #expect(!goal.contains("User requirements:"))
        #expect(!goal.contains("Scope id: send_only"))
        #expect(!goal.contains("Scope id: send_and_receive"))
    }

    @Test func connectorBuildGoalIgnoresFreeTextUserDescription() {
        let input = PluginFactoryCreateInput.makeConnector(
            vendor: .slack,
            scope: .fullSync,
            userDescription: "Also add reactions, file uploads, and slash commands."
        )
        let goal = input.connectorBuildGoal(crawlSummary: nil)
        #expect(!goal.contains("Also add reactions, file uploads, and slash commands."))
        #expect(!goal.contains("User requirements:"))
        #expect(!goal.localizedCaseInsensitiveContains("unless the user requirements"))
        #expect(goal.contains("Scope id: full_sync"))
        #expect(goal.localizedCaseInsensitiveContains("reply threads"))
        #expect(goal.contains("conversation.replies") || goal.contains("conversations.replies"))
    }

    @Test func connectorBuildGoalFullSyncIncludesReplyThreads() {
        let input = PluginFactoryCreateInput.makeConnector(
            vendor: .slack,
            scope: .fullSync,
            userDescription: ""
        )
        let goal = input.connectorBuildGoal(crawlSummary: nil)
        #expect(goal.localizedCaseInsensitiveContains("parent_vendor_message_id"))
        #expect(goal.localizedCaseInsensitiveContains("conversations.replies"))
        #expect(goal.localizedCaseInsensitiveContains("missing_scope"))
        #expect(goal.contains("must_not_call"))
        #expect(goal.contains("conversation.history"))
        #expect(goal.contains("runtime_empty_messages_ok_if_vendor_ok"))
        #expect(goal.contains("Scope id: full_sync"))
        #expect(PluginFactoryScopeHints.isFullSync(goal))
        #expect(PluginFactoryScopeHints.paginationGuidance(for: goal)?.contains("follow_cursor") == true)
    }

    @Test func connectorInputUsesScopeDefaultWhenDescriptionEmpty() {
        let input = PluginFactoryCreateInput.makeConnector(
            vendor: .slack,
            scope: .fullSync,
            userDescription: ""
        )
        #expect(!input.description.isEmpty)
        #expect(input.description.localizedCaseInsensitiveContains("Slack"))
        #expect(input.description.localizedCaseInsensitiveContains("conversations"))
        #expect(input.description.localizedCaseInsensitiveContains("reply"))
    }

    @Test func validationExpectationsParseDeclaredMessagingOpsFromGoal() {
        let fullSync = PluginFactoryCreateInput.makeConnector(
            vendor: .slack,
            scope: .fullSync,
            userDescription: "Alerts."
        )
        let goal = fullSync.connectorBuildGoal(crawlSummary: nil)
        let ops = PluginFactoryValidationExpectations.requiredMessagingOps(from: goal)
        #expect(ops.contains("sync_threads"))
        #expect(ops.contains("poll_inbox"))
        #expect(ops.contains("send_message"))
        #expect(ops == ["sync_threads", "poll_inbox", "send_message"] || Set(ops) == Set(["sync_threads", "poll_inbox", "send_message"]))
    }

    @Test func supportsThreadDiscoveryRequiresSyncThreadsOp() {
        let withDiscovery = """
        {"extensions":{"app.derrick":{"role":"connector","messaging_ops":["sync_threads","poll_inbox","send_message"]}}}
        """
        let withoutDiscovery = """
        {"extensions":{"app.derrick":{"role":"connector","messaging_ops":["poll_inbox","send_message"]}}}
        """
        #expect(PluginFactoryValidationExpectations.supportsThreadDiscovery(manifestJSON: withDiscovery))
        #expect(!PluginFactoryValidationExpectations.supportsThreadDiscovery(manifestJSON: withoutDiscovery))
    }

    @Test func pluginFactoryScopeHintsDetectFullSyncGoal() {
        let input = PluginFactoryCreateInput.makeConnector(
            vendor: .slack,
            scope: .fullSync,
            userDescription: "Alerts."
        )
        let goal = input.connectorBuildGoal(crawlSummary: nil)
        #expect(PluginFactoryScopeHints.isFullSync(goal))
        #expect(PluginFactoryScopeHints.paginationGuidance(for: goal)?.contains("follow_cursor") == true)
        #expect(PluginFactoryScopeHints.paginationGuidance(for: goal)?.contains("include_reply_poll=true") == true)
    }

    @Test func pluginFactoryCreateInputDecodesLegacyScopesAsFullSync() throws {
        let sendOnly = """
        {"pluginType":"connector","vendor":"slack","scope":"send_only","description":"x"}
        """
        let sendAndReceive = """
        {"pluginType":"connector","vendor":"slack","scope":"send_and_receive","description":"x"}
        """
        #expect(try PluginFactoryCreateInput.decodeJSON(sendOnly).scope == .fullSync)
        #expect(try PluginFactoryCreateInput.decodeJSON(sendAndReceive).scope == .fullSync)
    }

    @Test func pluginFactoryScopeHintsOverrideMisplacedFullSyncHistoryReview() {
        let goal = PluginFactoryCreateInput.makeConnector(
            vendor: .slack,
            scope: .fullSync,
            userDescription: ""
        ).connectorBuildGoal(crawlSummary: nil)
        let review = PluginFactoryReview(
            decision: .rejected,
            findings: [
                PluginReviewFinding(
                    severity: .blocking,
                    category: .correctness,
                    message: """
                    sync_threads only paginates conversations.list and emits channel tabs; \
                    it never fetches conversations.history or conversations.replies.
                    """
                ),
            ],
            summary: """
            Rejected: the requested fully paginated Slack sync—including channel history and reply threads—is not implemented or tested.
            """
        )
        #expect(PluginFactoryScopeHints.isMisplacedHistoryInSyncThreadsRejection(review))
        #expect(PluginFactoryScopeHints.isOverstrictFullSyncRejection(review))
        let override = PluginFactoryScopeHints.approvedOverride(for: review, userGoal: goal)
        #expect(override?.approved == true)
    }

    @Test func pluginFactoryScopeHintsOverrideEmptySuccessfulPollReview() {
        let goal = PluginFactoryCreateInput.makeConnector(
            vendor: .slack,
            scope: .fullSync,
            userDescription: ""
        ).connectorBuildGoal(crawlSummary: nil)
        let review = PluginFactoryReview(
            decision: .rejected,
            findings: [
                PluginReviewFinding(
                    severity: .blocking,
                    category: .correctness,
                    message: """
                    An empty Slack messages array is emitted as a successful inbox update.
                    """
                ),
            ],
            summary: "Rejected: empty Slack messages array is emitted as a successful inbox update."
        )
        #expect(PluginFactoryScopeHints.isEmptySuccessfulPollRejection(review))
        let override = PluginFactoryScopeHints.approvedOverride(for: review, userGoal: goal)
        #expect(override?.approved == true)
    }

    @Test func pluginFactoryScopeHintsKeepsSafetyRejectionForFullSync() {
        let goal = PluginFactoryCreateInput.makeConnector(
            vendor: .slack,
            scope: .fullSync,
            userDescription: ""
        ).connectorBuildGoal(crawlSummary: nil)
        let review = PluginFactoryReview(
            decision: .rejected,
            findings: [
                PluginReviewFinding(
                    severity: .blocking,
                    category: .safety,
                    message: "The source uses urllib to fetch Slack."
                ),
            ],
            summary: "Rejected: empty Slack messages array is emitted as a successful inbox update."
        )
        #expect(PluginFactoryScopeHints.approvedOverride(for: review, userGoal: goal) == nil)
    }

    @Test func validationExpectationsReadMessagingOpsFromManifestJSON() {
        let json = """
        {"extensions":{"app.derrick":{"role":"connector","messaging_ops":["send_message","poll_inbox"]}}}
        """
        let ops = PluginFactoryValidationExpectations.messagingOps(fromManifestJSON: json)
        #expect(ops == ["send_message", "poll_inbox"])
    }

    @Test func connectorPluginNamingIncrementsAcrossExistingIDs() {
        #expect(
            ConnectorPluginNaming.defaultPluginID(vendor: .slack, existingIDs: [])
                == "slack-connector-1"
        )
        #expect(
            ConnectorPluginNaming.defaultPluginID(
                vendor: .slack,
                existingIDs: ["slack-connector-1"]
            ) == "slack-connector-2"
        )
        #expect(
            ConnectorPluginNaming.defaultPluginID(
                vendor: .slack,
                existingIDs: ["slack-connection", "slack-connector", "slack-connector-1"]
            ) == "slack-connector-2"
        )
        #expect(ConnectorPluginNaming.isGeneratedDefault(pluginID: "slack-connector-1", vendor: .slack))
        #expect(ConnectorPluginNaming.isGeneratedDefault(pluginID: "slack-connector", vendor: .slack))
        #expect(!ConnectorPluginNaming.isGeneratedDefault(pluginID: "office-slack", vendor: .slack))
    }

    @Test func connectorAuthDiscoveryDecodesReviewerJSON() throws {
        let json = """
        {"auth_scheme":"bot_token","secrets":[{"id":"bot_token","label":"Bot Token","kind":"token"}],\
        "permissions":["chat:write"],"setup_hint":"Create a Slack bot.","crawl_summary":"Bearer token."}
        """
        let decoded = try JSONDecoder().decode(ConnectorAuthDiscovery.self, from: Data(json.utf8))
        #expect(decoded.authScheme == .botToken)
        #expect(decoded.secrets.map(\.id) == ["bot_token"])
        #expect(decoded.permissions == ["chat:write"])
        #expect(decoded.setupHint == "Create a Slack bot.")
        #expect(decoded.crawlSummary == "Bearer token.")
        #expect(decoded.authScheme.isSupportedInWizard)
        #expect(!ConnectorAuthScheme.oauth.isSupportedInWizard)
    }

    @Test func pluginFactoryCreateInputRoundTripsHostAuthAndPluginID() throws {
        let auth = try ConnectorAuthDiscovery.slackBotTokenFallback(crawlSummary: "Slack bot tokens.")
        let input = PluginFactoryCreateInput.makeConnector(
            vendor: .slack,
            pluginID: "slack-connector-2",
            auth: auth,
            scope: .fullSync
        )
        let decoded = try PluginFactoryCreateInput.decodeJSON(try input.encodedJSON())
        #expect(decoded.pluginID == "slack-connector-2")
        #expect(decoded.auth?.authScheme == .botToken)
        #expect(decoded.auth?.secrets.map(\.id) == ["bot_token"])
        #expect(decoded.auth?.crawlSummary == "Slack bot tokens.")
        let manifest = try #require(decoded.hostManifest)
        #expect(manifest.pluginID == "slack-connector-2")
        #expect(manifest.authScheme == .botToken)
        let manifestJSON = try manifest.encodedJSON()
        #expect(manifestJSON.contains("\"auth_scheme\":\"bot_token\""))
        #expect(manifestJSON.contains("\"name\":\"slack-connector-2\""))
        #expect(!manifestJSON.contains("xoxb-"))
    }

    @Test func makeConnectorDefaultsDistinctGeneratedPluginIDs() {
        let first = PluginFactoryCreateInput.makeConnector(vendor: .slack)
        #expect(first.pluginID == "slack-connector-1")
        let second = ConnectorPluginNaming.defaultPluginID(
            vendor: .slack,
            existingIDs: [first.pluginID].compactMap { $0 }
        )
        #expect(second == "slack-connector-2")
    }
}
