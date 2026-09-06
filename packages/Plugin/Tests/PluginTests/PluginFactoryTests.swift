import Foundation
import Structure
import Testing
@testable import Plugin

@Suite struct PluginFactoryTests {
    private func guestPythonSource(emit: String = #"[]"#) -> String {
        """
        import json, sys
        _ = json.load(sys.stdin)
        json.dump(\(emit), sys.stdout)
        """
    }

    @Test func guestLanguageIsAlwaysPython() {
        let release = PluginFactoryRelease(
            pluginID: "slack-connection",
            version: "1.0.0",
            manifestJSON: "{}",
            runtimeJSON: #"{"language":"python","entrypoint":"./app.derrick/plugin.py"}"#,
            guestSource: guestPythonSource(),
            compiledArtifact: Data(),
            skillFiles: [:],
            contentHash: try! PluginContentHash(hex: String(repeating: "b", count: 64)),
            reviewSummary: "ok"
        )
        #expect(release.guestLanguage == .python)
    }

    @Test func pluginFactoryRuntimeDecodesPythonEntrypoint() {
        let runtime = PluginFactoryRuntime.decode(
            from: #"{"language":"python","entrypoint":"./app.derrick/plugin.py"}"#
        )
        #expect(runtime?.language == .python)
        #expect(runtime?.entrypoint.hasSuffix(".py") == true)
    }

    @Test func envelopeDecoderRejectsNestedResultAliases() {
        let raw = "[{\"verb\":\"result.emit\",\"result\":{\"emit\":{\"content\":\"## News digest\"}}}]"
        #expect(throws: GuestContractError.self) {
            _ = try PluginEnvelopeList.decode(Data(raw.utf8))
        }
    }

    @Test func buildRunsDraftReviewsCompilesAndVerifiesRelease() async throws {
        let executor = RecordingFactoryExecutor()
        let reviewer = RecordingFactoryReviewer(result: PluginFactoryReview(approved: true, summary: "safe"))
        let draft = PluginFactoryDraft(
            manifestJSON: manifestJSON(),
            guestSource: guestPythonSource(),
            testInput: Data(#"{"kind":"manual"}"#.utf8),
            skillFiles: ["skills/weather/SKILL.md": "# Weather\n\nReturn weather."]
        )

        let release = try await PluginFactory().build(
            draft: draft,
            executor: executor,
            reviewer: reviewer
        )

        #expect(release.pluginID == "weather-tool")
        #expect(release.version == "1.2.3")
        #expect(release.runtimeJSON.contains("\"language\":\"python\""))
        #expect(release.runtimeJSON.contains("plugin.py"))
        #expect(!release.contentHash.rawValue.isEmpty)
        #expect(release.verifyIntegrity())
        var tampered = release.packageFiles()
        tampered["app.derrick/plugin.py"] = Data("changed".utf8)
        #expect(!PluginFactoryRelease.verifyIntegrity(files: tampered, expected: release.contentHash))
        #expect(await executor.draftRunCount == 1)
        #expect(await executor.packageCount == 1)
        #expect(await executor.packagedRunCount == 1)
        #expect(await reviewer.callCount == 1)
    }

    @Test func rejectedReviewStopsBeforePackaging() async throws {
        let executor = RecordingFactoryExecutor()
        let reviewer = RecordingFactoryReviewer(
            result: PluginFactoryReview(approved: false, summary: "source is not safe")
        )

        do {
            _ = try await PluginFactory().build(
                draft: PluginFactoryDraft(
                    manifestJSON: manifestJSON(),
                    guestSource: guestPythonSource()
                ),
                executor: executor,
                reviewer: reviewer
            )
            Issue.record("Expected review rejection")
        } catch let error as PluginFactoryError {
            #expect(error == .reviewRejected(summary: "source is not safe", findings: []))
            #expect(await executor.packageCount == 0)
            #expect(await executor.packagedRunCount == 0)
        }
    }

    @Test func invalidDraftOutputStopsBeforeReview() async throws {
        let executor = RecordingFactoryExecutor(
            draftResult: PluginFactoryExecutionResult(
                exitCode: 0,
                stdout: Data(#"{"not":"an array"}"#.utf8)
            )
        )
        let reviewer = RecordingFactoryReviewer(result: PluginFactoryReview(approved: true, summary: "safe"))

        do {
            _ = try await PluginFactory().build(
                draft: PluginFactoryDraft(
                    manifestJSON: manifestJSON(),
                    guestSource: """
                    import json, sys
                    _ = json.load(sys.stdin)
                    print("not a plugin envelope")
                    """,
                    testInput: Data(#"{"kind":"manual"}"#.utf8)
                ),
                executor: executor,
                reviewer: reviewer
            )
            Issue.record("Expected invalid output")
        } catch let error as PluginFactoryError {
            #expect(
                error.localizedDescription.contains("invalid plugin output")
                    || error.localizedDescription.contains("Python draft test failed")
            )
            #expect(await reviewer.callCount == 0)
        }
    }

    @Test func sessionAllowsOnlyBoundedBuilderCorrectionBeforeRelease() async throws {
        let executor = RecordingFactoryExecutor(
            firstDraftResult: PluginFactoryExecutionResult(
                exitCode: 1,
                stderr: Data("compile error".utf8)
            )
        )
        let reviewer = RecordingFactoryReviewer(result: PluginFactoryReview(approved: true, summary: "safe"))
        let builder = RecordingFactoryBuilder(draft: draft())

        let release = try await PluginFactorySession(
            configuration: PluginFactoryConfiguration(maxBuilderAttempts: 2)
        ).build(
            userGoal: "make a weather plugin",
            builder: builder,
            executor: executor,
            reviewer: reviewer
        )

        #expect(release.pluginID == "weather-tool")
        #expect(await executor.draftRunCount == 2)
        #expect(await executor.packageCount == 1)
        let requests = await builder.requests
        #expect(requests.count == 2)
        #expect(requests[1].feedback?.contains("compile error") == true)
        #expect(await reviewer.callCount == 1)
    }

    @Test func sessionRetriesReviewRejectionWithReviewerFeedback() async throws {
        let executor = RecordingFactoryExecutor()
        let reviewer = RecordingFactoryReviewer(
            results: [
                PluginFactoryReview(
                    decision: .rejected,
                    findings: [
                        PluginReviewFinding(
                            severity: .blocking,
                            category: .correctness,
                            message: "Sort the returned items by a stable key."
                        )
                    ],
                    summary: "The first draft is not deterministic."
                ),
                PluginFactoryReview(approved: true, summary: "safe")
            ]
        )
        let builder = RecordingFactoryBuilder(draft: draft())

        let release = try await PluginFactorySession().build(
            userGoal: "make a weather plugin",
            builder: builder,
            executor: executor,
            reviewer: reviewer
        )

        #expect(release.pluginID == "weather-tool")
        #expect(await reviewer.callCount == 2)
        #expect(await executor.draftRunCount == 2)
        #expect(await executor.packageCount == 1)
        let requests = await builder.requests
        #expect(requests.count == 2)
        #expect(requests[1].feedback?.contains("Sort the returned items") == true)
    }

    @Test func sessionRejectsAfterReviewAttemptBudgetIsExhausted() async throws {
        let executor = RecordingFactoryExecutor()
        let reviewer = RecordingFactoryReviewer(
            result: PluginFactoryReview(approved: false, summary: "The draft remains unsafe.")
        )
        let builder = RecordingFactoryBuilder(draft: draft())

        do {
            _ = try await PluginFactorySession(
                configuration: PluginFactoryConfiguration(maxBuilderAttempts: 3)
            ).build(
                userGoal: "make a weather plugin",
                builder: builder,
                executor: executor,
                reviewer: reviewer
            )
            Issue.record("Expected review rejection")
        } catch let error as PluginFactoryError {
            #expect(error == .reviewRejected(summary: "The draft remains unsafe.", findings: []))
            #expect(await reviewer.callCount == 3)
            #expect(await executor.draftRunCount == 3)
            #expect(await executor.packageCount == 0)
            #expect(await builder.requests.count == 3)
        }
    }

    @Test func reservedPluginIDsCannotBeCreated() async {
        let draft = PluginFactoryDraft(
            manifestJSON: manifestJSON().replacingOccurrences(of: "weather-tool", with: "create-plugin"),
            guestSource: guestPythonSource(),
        )
        do {
            _ = try await PluginFactory().build(
                draft: draft,
                executor: RecordingFactoryExecutor(),
                reviewer: RecordingFactoryReviewer(
                    result: PluginFactoryReview(approved: true, summary: "safe")
                )
            )
            Issue.record("Expected reserved plugin id rejection")
        } catch let error as PluginFactoryError {
            #expect(error == .reservedPluginID("create-plugin"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func missingSchemaIsRejectedAtTheFactoryBoundary() async {
        let manifest = """
        {"name":"weather-tool","version":"1.0.0","extensions":{"app.derrick":{"entrypoint":"./app.derrick/plugin.py"}}}
        """
        do {
            _ = try await PluginFactory().build(
                draft: PluginFactoryDraft(
                    manifestJSON: manifest,
                    guestSource: guestPythonSource()
                ),
                executor: RecordingFactoryExecutor(),
                reviewer: RecordingFactoryReviewer(
                    result: PluginFactoryReview(approved: true, summary: "safe")
                )
            )
            Issue.record("Expected a missing schema to be rejected")
        } catch let error as PluginFactoryError {
            #expect(error.localizedDescription.contains("$schema"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func builderResponseCreatesCanonicalManifest() throws {
        let response = PluginFactoryBuilderResponse(
            pluginID: "weather-tool",
            version: "1.0.0",
            description: "Weather summaries.",
            guestSource: guestPythonSource(),
        )
        let draft = try response.draft()
        let manifest = try AgentPluginManifest.decode(Data(draft.manifestJSON.utf8))
        #expect(manifest.schema == PluginContract.agentPluginSchema)
        #expect(manifest.derrick?.entrypoint == "./app.derrick/plugin.py")
    }

    @Test func builderNormalizesUnderscorePluginIDAndWritesSecretLabels() throws {
        let response = PluginFactoryBuilderResponse(
            pluginID: "slack_connection",
            version: "1.0.0",
            description: "Slack send and receive.",
            guestSource: guestPythonSource(),
            secrets: [
                try PluginSecretField(id: "username", label: "Slack username", kind: .username),
                try PluginSecretField(id: "password", label: "Slack password", kind: .password),
            ]
        )
        let draft = try response.draft()
        let manifest = try AgentPluginManifest.decode(Data(draft.manifestJSON.utf8))
        #expect(manifest.name.rawValue == "slack-connection")
        #expect(manifest.derrick?.secrets.map(\.id) == ["username", "password"])
        #expect(manifest.derrick?.secrets.map(\.label) == ["Slack username", "Slack password"])
        #expect(draft.manifestJSON.contains("slack_connection") == false)
    }

    @Test func builderWritesConnectorRoleIntoCanonicalManifest() throws {
        let response = PluginFactoryBuilderResponse(
            pluginID: "slack-connection",
            version: "1.0.0",
            description: "Slack send and receive.",
            guestSource: guestPythonSource(),
            role: .connector,
            messagingOps: ["send_message"]
        )
        let draft = try response.draft()
        let manifest = try AgentPluginManifest.decode(Data(draft.manifestJSON.utf8))
        #expect(manifest.isConnector)
        #expect(manifest.derrick?.role == .connector)
        #expect(draft.manifestJSON.contains("\"messaging_ops\":[\"send_message\"]"))
    }

    @Test func connectorManifestDefaultsMessagingOpsWhenOmitted() throws {
        let response = PluginFactoryBuilderResponse(
            pluginID: "slack-connection",
            version: "1.0.0",
            description: "Slack full sync.",
            guestSource: guestPythonSource(),
            role: .connector
        )
        let draft = try response.draft()
        #expect(draft.manifestJSON.contains("\"messaging_ops\":[\"sync_threads\",\"poll_inbox\",\"send_message\"]"))
    }

    @Test func connectorTestScriptRequiresHopsAndFixtures() throws {
        let manifestJSON = """
        {"$schema":"\(PluginContract.agentPluginSchema)","name":"slack-connection","version":"1.0.0",\
        "extensions":{"app.derrick":{"entrypoint":"./app.derrick/plugin.py","role":"connector","messaging_ops":["sync_threads","poll_inbox","send_message"]}}}
        """
        let manifest = try AgentPluginManifest.decode(Data(manifestJSON.utf8))
        #expect(throws: PluginFactoryError.self) {
            _ = try PluginFactoryTestScript.parse(Data(#"{"hops":[]}"#.utf8))
        }
        let draft = PluginFactoryDraft(
            manifestJSON: manifestJSON,
            guestSource: guestPythonSource(),
            testInput: Data(
                #"{"kind":"message_in_room","params":{"messaging_op":"send_message"}}"#.utf8
            ),
            userGoal: fullSyncGoal()
        )
        #expect(throws: PluginFactoryError.self) {
            try PluginFactoryDraftValidator.validateStructure(draft: draft, manifest: manifest)
        }
        let validDraft = connectorDraft(testInput: validConnectorTestInput())
        try PluginFactoryDraftValidator.validateStructure(draft: validDraft, manifest: manifest)
    }

    @Test func hopTestRunnerReplaysAllScriptHops() async throws {
        let executor = MultiHopRecordingFactoryExecutor()
        let testInput = Data(
            """
            {"hops":[
              {"kind":"message_in_room","params":{"messaging_op":"send_message"}},
              {"kind":"http_results","http_results":[{"request_id":"send-1","status":200,"body":"{\\"ok\\":true}"}]},
              {"kind":"manual","params":{"messaging_op":"poll_inbox"}},
              {"kind":"http_results","http_results":[{"request_id":"poll-1","status":200,"body":"{\\"ok\\":true,\\"messages\\":[]}"}]}
            ]}
            """.utf8
        )
        let run = try await PluginFactoryHopTestRunner.run(
            source: "print('unused')",
            testInput: testInput,
            executor: executor
        )
        #expect(run.final.exitCode == 0)
        #expect(await executor.runCount == 4)
    }

    @Test func fullSyncTestScriptRequiresReplyThreadPollHop() throws {
        let manifestJSON = """
        {"$schema":"\(PluginContract.agentPluginSchema)","name":"slack-connection","version":"1.0.0",\
        "extensions":{"app.derrick":{"entrypoint":"./app.derrick/plugin.py","role":"connector","messaging_ops":["sync_threads","poll_inbox","send_message"]}}}
        """
        let manifest = try AgentPluginManifest.decode(Data(manifestJSON.utf8))
        let channelOnly = Data(
            """
            {"hops":[
              {"kind":"manual","params":{"messaging_op":"sync_threads"}},
              {"kind":"http_results","http_results":[{"request_id":"sync-1","status":200,"body":"{\\"ok\\":true}"}],"params":{"messaging_op":"sync_threads"}},
              {"kind":"manual","params":{"messaging_op":"poll_inbox","vendor_thread_id":"C123"}},
              {"kind":"http_results","http_results":[{"request_id":"poll-1","status":200,"body":"{\\"ok\\":true}"}],"params":{"messaging_op":"poll_inbox"}},
              {"kind":"message_in_room","params":{"messaging_op":"send_message","vendor_thread_id":"C123","text":"hello"}},
              {"kind":"http_results","http_results":[{"request_id":"send-1","status":200,"body":"{\\"ok\\":true}"}],"params":{"messaging_op":"send_message"}}
            ]}
            """.utf8
        )
        let missingReplies = PluginFactoryDraft(
            manifestJSON: manifestJSON,
            guestSource: guestPythonSource(),
            testInput: channelOnly,
            userGoal: fullSyncGoal()
        )
        #expect(throws: PluginFactoryError.self) {
            try PluginFactoryDraftValidator.validateStructure(draft: missingReplies, manifest: manifest)
        }

        let withReplies = PluginFactoryDraft(
            manifestJSON: manifestJSON,
            guestSource: guestPythonSource(),
            testInput: Data(
                """
                {"hops":[
                  {"kind":"manual","params":{"messaging_op":"sync_threads"}},
                  {"kind":"http_results","http_results":[{"request_id":"sync-1","status":200,"body":"{\\"ok\\":true}"}],"params":{"messaging_op":"sync_threads"}},
                  {"kind":"manual","params":{"messaging_op":"poll_inbox","vendor_thread_id":"C123"}},
                  {"kind":"http_results","http_results":[{"request_id":"poll-1","status":200,"body":"{\\"ok\\":true}"}],"params":{"messaging_op":"poll_inbox"}},
                  {"kind":"manual","params":{"messaging_op":"poll_inbox","vendor_thread_id":"C123","parent_vendor_message_id":"171.1"}},
                  {"kind":"http_results","http_results":[{"request_id":"replies-1","status":200,"body":"{\\"ok\\":true}"}],"params":{"messaging_op":"poll_inbox"}},
                  {"kind":"message_in_room","params":{"messaging_op":"send_message","vendor_thread_id":"C123","text":"hello"}},
                  {"kind":"http_results","http_results":[{"request_id":"send-1","status":200,"body":"{\\"ok\\":true}"}],"params":{"messaging_op":"send_message"}}
                ]}
                """.utf8
            ),
            userGoal: fullSyncGoal()
        )
        try PluginFactoryDraftValidator.validateStructure(draft: withReplies, manifest: manifest)
    }

    @Test func dualFixtureAllowsUnsortedHttpResultsLoop() throws {
        let manifestJSON = """
        {"$schema":"\(PluginContract.agentPluginSchema)","name":"slack-connection","version":"1.0.0",\
        "extensions":{"app.derrick":{"entrypoint":"./app.derrick/plugin.py","role":"connector","messaging_ops":["sync_threads","poll_inbox","send_message"]}}}
        """
        let manifest = try AgentPluginManifest.decode(Data(manifestJSON.utf8))
        let testInput = Data(
            """
            {"hops":[
              {"kind":"manual","params":{"messaging_op":"sync_threads"}},
              {"kind":"http_results","http_results":[{"request_id":"sync-1","status":200,"body":"{\\"ok\\":true}"}],"params":{"messaging_op":"sync_threads"}},
              {"kind":"manual","params":{"messaging_op":"poll_inbox","vendor_thread_id":"C1"}},
              {"kind":"http_results","http_results":[{"request_id":"poll-1","status":200,"body":"{\\"ok\\":true}"}],"params":{"messaging_op":"poll_inbox"}},
              {"kind":"manual","params":{"messaging_op":"poll_inbox","vendor_thread_id":"C1","parent_vendor_message_id":"1"}},
              {"kind":"http_results","http_results":[{"request_id":"replies-1","status":200,"body":"{\\"ok\\":true}"}],"params":{"messaging_op":"poll_inbox"}},
              {"kind":"message_in_room","params":{"messaging_op":"send_message","vendor_thread_id":"C1","text":"hi"}},
              {"kind":"http_results","http_results":[
                {"request_id":"send-1","status":200,"body":"{\\"ok\\":true,\\"ts\\":\\"1.0\\"}"},
                {"request_id":"auth-1","status":401,"body":"{\\"ok\\":false,\\"error\\":\\"invalid_auth\\"}"}
              ],"params":{"messaging_op":"send_message"}}
            ]}
            """.utf8
        )
        let draft = PluginFactoryDraft(
            manifestJSON: manifestJSON,
            guestSource: """
            import json, sys
            event = json.load(sys.stdin)
            for item in event.get("http_results") or []:
                if item.get("request_id") == "send-1":
                    body = json.loads(item.get("body") or "{}")
                    if body.get("ok"):
                        json.dump([{"verb":"result.emit","sent_message":{"vendor_message_id":"1.0","created_at":"1.0"}}], sys.stdout)
                        sys.exit(0)
            json.dump([{"verb":"result.emit","summary":"failed"}], sys.stdout)
            """,
            testInput: testInput,
            userGoal: fullSyncGoal()
        )
        try PluginFactoryDraftValidator.validateStructure(draft: draft, manifest: manifest)
    }

    @Test func draftValidationFailureIsBuilderCorrectable() {
        #expect(
            PluginFactoryError.draftValidationFailed(findings: ["missing messaging_ops"]).isBuilderCorrectable
        )
    }

    @Test func sessionRetriesDraftValidationWithBuilderFeedback() async throws {
        let executor = MultiHopRecordingFactoryExecutor()
        let reviewer = RecordingFactoryReviewer(result: PluginFactoryReview(approved: true, summary: "safe"))
        let invalidDraft = connectorDraft(testInput: Data(#"{"kind":"manual"}"#.utf8))
        let validDraft = connectorDraft(testInput: validConnectorTestInput())
        let builder = SequenceFactoryBuilder(drafts: [invalidDraft, validDraft])

        let release = try await PluginFactorySession(
            configuration: PluginFactoryConfiguration(maxBuilderAttempts: 2)
        ).build(
            userGoal: fullSyncGoal(),
            builder: builder,
            executor: executor,
            reviewer: reviewer
        )

        #expect(release.pluginID == "slack-connection")
        #expect(await builder.callCount == 2)
        let feedback = await builder.lastFeedback ?? ""
        #expect(feedback.contains("Deterministic draft validation failed"))
    }

    @Test func missingRoleDefaultsToStandard() throws {
        let json = """
        {"$schema":"\(PluginContract.agentPluginSchema)","name":"weather-tool","version":"1.0.0","extensions":{"app.derrick":{"entrypoint":"./app.derrick/plugin.py"}}}
        """
        let manifest = try AgentPluginManifest.decode(Data(json.utf8))
        #expect(manifest.derrick?.role == .standard)
        #expect(!manifest.isConnector)
    }

    @Test func invalidRoleIsRejected() {
        let json = """
        {"$schema":"\(PluginContract.agentPluginSchema)","name":"weather-tool","version":"1.0.0","extensions":{"app.derrick":{"entrypoint":"./app.derrick/plugin.py","role":"slack"}}}
        """
        do {
            _ = try AgentPluginManifest.decode(Data(json.utf8))
            Issue.record("Expected invalid role rejection")
        } catch let error as PluginManifestError {
            #expect(error == .invalidRole("slack"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func invalidSourceIsBuilderCorrectable() {
        #expect(
            PluginFactoryError.invalidSource("test_input_json must be valid JSON.").isBuilderCorrectable
        )
    }

    @Test func invalidManifestIsBuilderCorrectable() {
        #expect(PluginFactoryError.invalidManifest("Invalid plugin id 'slack_connection'.").isBuilderCorrectable)
    }

    @Test func builderRejectsInvalidSkillPathBeforeFactoryExecution() {
        let response = PluginFactoryBuilderResponse(
            pluginID: "weather-tool",
            version: "1.0.0",
            description: "Weather summaries.",
            guestSource: guestPythonSource(),
            skillFiles: [
                PluginFactorySkillFile(path: "SKILL.md", body: "Invalid layout.")
            ]
        )

        do {
            _ = try response.draft()
            Issue.record("Expected invalid skill path rejection")
        } catch let error as PluginFactoryError {
            #expect(error == .invalidSkillPath("SKILL.md"))
            #expect(error.isBuilderCorrectable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func draft() -> PluginFactoryDraft {
        PluginFactoryDraft(
            manifestJSON: manifestJSON(),
            guestSource: guestPythonSource(),
            testInput: Data(#"{"kind":"manual"}"#.utf8)
        )
    }

    private func manifestJSON() -> String {
        """
        {"$schema":"\(PluginContract.agentPluginSchema)","name":"weather-tool","version":"1.2.3","extensions":{"app.derrick":{"entrypoint":"./app.derrick/plugin.py"}}}
        """
    }
}

private func fullSyncGoal() -> String {
    PluginFactoryCreateInput.makeConnector(
        vendor: .slack,
        scope: .fullSync,
        userDescription: ""
    ).connectorBuildGoal(crawlSummary: nil)
}

private func validConnectorTestInput() -> Data {
    Data(
        """
        {"hops":[
          {"kind":"manual","params":{"messaging_op":"sync_threads"}},
          {"kind":"http_results","http_results":[{"request_id":"sync-1","status":200,"body":"{\\"ok\\":true}"}],"params":{"messaging_op":"sync_threads"}},
          {"kind":"manual","params":{"messaging_op":"poll_inbox","vendor_thread_id":"C1"}},
          {"kind":"http_results","http_results":[{"request_id":"poll-1","status":200,"body":"{\\"ok\\":true}"}],"params":{"messaging_op":"poll_inbox"}},
          {"kind":"manual","params":{"messaging_op":"poll_inbox","vendor_thread_id":"C1","parent_vendor_message_id":"1"}},
          {"kind":"http_results","http_results":[{"request_id":"replies-1","status":200,"body":"{\\"ok\\":true}"}],"params":{"messaging_op":"poll_inbox"}},
          {"kind":"message_in_room","params":{"messaging_op":"send_message","vendor_thread_id":"C1","text":"hi"}},
          {"kind":"http_results","http_results":[{"request_id":"send-1","status":200,"body":"{\\"ok\\":true}"}],"params":{"messaging_op":"send_message"}}
        ]}
        """.utf8
    )
}

private func connectorDraft(testInput: Data) -> PluginFactoryDraft {
    let manifestJSON = """
    {"$schema":"\(PluginContract.agentPluginSchema)","name":"slack-connection","version":"1.0.0",\
    "extensions":{"app.derrick":{"entrypoint":"./app.derrick/plugin.py","role":"connector","messaging_ops":["sync_threads","poll_inbox","send_message"]}}}
    """
    return PluginFactoryDraft(
        manifestJSON: manifestJSON,
        guestSource: """
        import json, sys
        event = json.load(sys.stdin)
        def emit(v):
            json.dump(v, sys.stdout, separators=(",", ":"))
        if event.get("http_results"):
            emit([{"verb":"result.emit","sent_message":{"vendor_message_id":"1.0","created_at":"1710000001.0"}}])
        else:
            emit([{"verb":"http.request","request_id":"send-1","method":"POST","url":"https://slack.com/api/chat.postMessage"}])
        """,
        testInput: testInput
    )
}

private actor SequenceFactoryBuilder: PluginFactoryBuilder {
    let drafts: [PluginFactoryDraft]
    private(set) var callCount = 0
    private(set) var lastFeedback: String?

    init(drafts: [PluginFactoryDraft]) {
        self.drafts = drafts
    }

    func makeDraft(_ request: PluginFactoryBuilderRequest) async throws -> PluginFactoryDraft {
        lastFeedback = request.feedback
        let index = min(callCount, drafts.count - 1)
        callCount += 1
        return drafts[index]
    }
}

private actor MultiHopRecordingFactoryExecutor: PluginFactoryExecutor {
    private(set) var runCount = 0

    func runGuestSource(source: String, input: Data) async throws -> PluginFactoryExecutionResult {
        _ = source
        let event = try JSONDecoder().decode(PluginHopEvent.self, from: input)
        runCount += 1
        if event.kind == .httpResults {
            return PluginFactoryExecutionResult(
                exitCode: 0,
                stdout: Data(
                    #"[{"verb":"result.emit","threads":[{"vendor_thread_id":"C1","title":"general"}],"messages":[{"vendor_thread_id":"C1","vendor_message_id":"1","direction":"inbound","sender":"a","body":"hi","created_at":"1"}],"sent_message":{"vendor_message_id":"1.0","created_at":"1710000001.0"}}]"#.utf8
                )
            )
        }
        let op = event.params?["messaging_op"]?.stringValue ?? ""
        let parent = event.params?["parent_vendor_message_id"]?.stringValue
        let requestID: String
        let method: String
        let url: String
        if op == "sync_threads" {
            requestID = "sync-1"
            method = "GET"
            url = "https://slack.com/api/conversations.list"
        } else if op == "poll_inbox", let parent, !parent.isEmpty {
            requestID = "replies-1"
            method = "GET"
            url = "https://slack.com/api/conversations.replies?channel=C1&ts=1"
        } else if op == "poll_inbox" {
            requestID = "poll-1"
            method = "GET"
            url = "https://slack.com/api/conversations.history?channel=C1"
        } else {
            requestID = "send-1"
            method = "POST"
            url = "https://slack.com/api/chat.postMessage"
        }
        return PluginFactoryExecutionResult(
            exitCode: 0,
            stdout: Data(
                #"[{"verb":"http.request","request_id":"\#(requestID)","method":"\#(method)","url":"\#(url)"}]"#.utf8
            )
        )
    }

    func packageGuestSource(source: String) async throws -> Data { Data(source.utf8) }

    func runPackagedArtifact(_ artifact: Data, input: Data) async throws -> PluginFactoryExecutionResult {
        try await runGuestSource(source: "", input: input)
    }
}

private actor RecordingFactoryExecutor: PluginFactoryExecutor {
    let draftResult: PluginFactoryExecutionResult
    let firstDraftResult: PluginFactoryExecutionResult?
    private(set) var draftRunCount = 0
    private(set) var packageCount = 0
    private(set) var packagedRunCount = 0

    init(
        draftResult: PluginFactoryExecutionResult = PluginFactoryExecutionResult(
            exitCode: 0,
            stdout: Data(#"[{"verb":"result.emit","summary":"ok"}]"#.utf8)
        ),
        firstDraftResult: PluginFactoryExecutionResult? = nil
    ) {
        self.draftResult = draftResult
        self.firstDraftResult = firstDraftResult
    }

    func runGuestSource(source: String, input: Data) async throws -> PluginFactoryExecutionResult {
        _ = source
        _ = input
        draftRunCount += 1
        return draftRunCount == 1 ? (firstDraftResult ?? draftResult) : draftResult
    }

    func packageGuestSource(source: String) async throws -> Data {
        _ = source
        packageCount += 1
        return Data(source.utf8)
    }

    func runPackagedArtifact(_ artifact: Data, input: Data) async throws -> PluginFactoryExecutionResult {
        _ = artifact
        _ = input
        packagedRunCount += 1
        return PluginFactoryExecutionResult(
            exitCode: 0,
            stdout: Data(#"[{"verb":"result.emit","summary":"ok"}]"#.utf8)
        )
    }
}

private actor RecordingFactoryBuilder: PluginFactoryBuilder {
    let draft: PluginFactoryDraft
    private(set) var requests: [PluginFactoryBuilderRequest] = []

    init(draft: PluginFactoryDraft) {
        self.draft = draft
    }

    func makeDraft(_ request: PluginFactoryBuilderRequest) async throws -> PluginFactoryDraft {
        requests.append(request)
        return draft
    }
}

private actor RecordingFactoryReviewer: PluginFactoryReviewer {
    let results: [PluginFactoryReview]
    private(set) var callCount = 0

    init(result: PluginFactoryReview) {
        self.results = [result]
    }

    init(results: [PluginFactoryReview]) {
        self.results = results
    }

    func review(
        draft: PluginFactoryDraft,
        directRun: PluginFactoryExecutionResult
    ) async throws -> PluginFactoryReview {
        _ = draft
        _ = directRun
        let result = results[min(callCount, results.count - 1)]
        callCount += 1
        return result
    }
}
