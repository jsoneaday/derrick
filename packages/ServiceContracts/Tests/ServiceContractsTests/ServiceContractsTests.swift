import Foundation
import Testing
@testable import ServiceContracts

@Suite struct ServiceContractsTests {
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

    @Test func bundledScriptReviewerInstructionsLoadFromSourceTree() throws {
        let scriptReviewer = try DerrickBundledText.load("script_reviewer_instructions.md")
        #expect(scriptReviewer.contains("intent alignment"))
        #expect(scriptReviewer.contains("secret literals"))
        #expect(scriptReviewer.contains("Swift verifier"))
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
            helperReviewerModelJSON: wireJSON
        )
        let data = try MCPServiceXPCCodec.encodeToolCallRequest(request)
        let decoded = try MCPServiceXPCCodec.decodeToolCallRequest(data)
        #expect(decoded.toolName == "script_exec")
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
        let id = "FE1AB9C3-C51F-4A8D-AB94-0C01E9357D19"
        DerrickJobResultPresentationWake.post(resultID: id)
        defer { _ = DerrickJobResultPresentationWake.takePendingResultID() }
        #expect(DerrickNotificationLaunch.hasJobResultPresentationIntent([]))
        #expect(!DerrickNotificationLaunch.isJobResultPresentationLaunch([]))
    }

    @Test func derrickUISessionPresenceTracksLivePID() {
        DerrickUISessionPresence.clearInteractiveSession()
        defer { DerrickUISessionPresence.clearInteractiveSession() }
        #expect(!DerrickUISessionPresence.isInteractiveSessionActive())
        DerrickUISessionPresence.markInteractiveSessionActive()
        #expect(DerrickUISessionPresence.isInteractiveSessionActive(excludingPID: -1))
        #expect(!DerrickUISessionPresence.isInteractiveSessionActive())
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
            DerrickDaemonHygiene.shouldRestartDaemonAfterReconcile(
                evictedAny: false,
                hasHealthyExpectedDaemon: false
            )
        )
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
        #expect(reason == .staleBuild)
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
        #expect(reason == .staleBuild)
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
            !DerrickDaemonHygiene.shouldRetireConnectedDaemon(
                reportedFingerprint: "a",
                expectedFingerprint: "a",
                reportedGuestRuntime: DerrickGuestRuntime.swiftPluginDockerImage,
                expectedGuestRuntime: DerrickGuestRuntime.swiftPluginDockerImage
            )
        )
        #expect(
            DerrickDaemonHygiene.shouldRetireConnectedDaemon(
                reportedFingerprint: "old",
                expectedFingerprint: "new",
                reportedGuestRuntime: DerrickGuestRuntime.swiftPluginDockerImage,
                expectedGuestRuntime: DerrickGuestRuntime.swiftPluginDockerImage
            )
        )
        #expect(
            DerrickDaemonHygiene.shouldRetireConnectedDaemon(
                reportedFingerprint: "a",
                expectedFingerprint: "a",
                reportedGuestRuntime: "stale-guest:old",
                expectedGuestRuntime: DerrickGuestRuntime.swiftPluginDockerImage
            )
        )
        #expect(
            DerrickDaemonHygiene.shouldRetireConnectedDaemon(
                reportedFingerprint: nil,
                expectedFingerprint: "a",
                reportedGuestRuntime: DerrickGuestRuntime.swiftPluginDockerImage,
                expectedGuestRuntime: DerrickGuestRuntime.swiftPluginDockerImage
            )
        )
        #expect(
            !DerrickDaemonHygiene.shouldRetireConnectedDaemon(
                reportedFingerprint: "a",
                expectedFingerprint: nil,
                reportedGuestRuntime: DerrickGuestRuntime.swiftPluginDockerImage,
                expectedGuestRuntime: DerrickGuestRuntime.swiftPluginDockerImage
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
        #expect(policy.warmStandbyCount == 1)
        #expect(policy.containerRunMaxTTLSeconds == 7 * 60)
        #expect(policy.destroyAfterEveryRun)
        #expect(policy.neverReusePostExecution)
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
}
