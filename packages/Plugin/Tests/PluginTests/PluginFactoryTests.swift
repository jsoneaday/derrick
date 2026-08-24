import Foundation
import Testing
@testable import Plugin

@Suite struct PluginFactoryTests {
    @Test func envelopeDecoderFlattensNestedResultAliases() throws {
        let raw = "[{\"verb\":\"result\",\"result\":{\"emit\":{\"content\":\"## News digest\"}}}]"
        let envelopes = try PluginEnvelopeList.decode(Data(raw.utf8))

        #expect(envelopes.count == 1)
        #expect(envelopes[0].verb == .resultEmit)
        #expect(envelopes[0].payload["content"]?.stringValue == "## News digest")
    }

    @Test func buildRunsDraftReviewsCompilesAndVerifiesRelease() async throws {
        let executor = RecordingFactoryExecutor()
        let reviewer = RecordingFactoryReviewer(result: PluginFactoryReview(approved: true, summary: "safe"))
        let draft = PluginFactoryDraft(
            manifestJSON: manifestJSON(),
            swiftSource: "import Foundation\nprint(\"[]\")",
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
        #expect(release.runtimeJSON.contains("\"language\":\"swift\""))
        #expect(release.runtimeJSON.contains("plugin.swift"))
        #expect(!release.contentHash.rawValue.isEmpty)
        #expect(release.verifyIntegrity())
        var tampered = release.packageFiles()
        tampered["app.derrick/plugin.swift"] = Data("changed".utf8)
        #expect(!PluginFactoryRelease.verifyIntegrity(files: tampered, expected: release.contentHash))
        #expect(await executor.draftRunCount == 1)
        #expect(await executor.compileCount == 1)
        #expect(await executor.compiledRunCount == 1)
        #expect(await reviewer.callCount == 1)
    }

    @Test func rejectedReviewStopsBeforeCompilation() async throws {
        let executor = RecordingFactoryExecutor()
        let reviewer = RecordingFactoryReviewer(
            result: PluginFactoryReview(approved: false, summary: "source is not safe")
        )

        do {
            _ = try await PluginFactory().build(
                draft: PluginFactoryDraft(
                    manifestJSON: manifestJSON(),
                    swiftSource: "import Foundation\nprint(\"[]\")"
                ),
                executor: executor,
                reviewer: reviewer
            )
            Issue.record("Expected review rejection")
        } catch let error as PluginFactoryError {
            #expect(error == .reviewRejected("source is not safe"))
            #expect(await executor.compileCount == 0)
            #expect(await executor.compiledRunCount == 0)
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
                    swiftSource: "print(\"not a plugin envelope\")"
                ),
                executor: executor,
                reviewer: reviewer
            )
            Issue.record("Expected invalid output")
        } catch let error as PluginFactoryError {
            #expect(error.localizedDescription.contains("invalid plugin output"))
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
        #expect(await executor.compileCount == 1)
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
        #expect(await executor.compileCount == 1)
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
            #expect(error == .reviewRejected("The draft remains unsafe."))
            #expect(await reviewer.callCount == 3)
            #expect(await executor.draftRunCount == 3)
            #expect(await executor.compileCount == 0)
            #expect(await builder.requests.count == 3)
        }
    }

    @Test func reservedSystemPluginIDsCannotBeCreated() async {
        let draft = PluginFactoryDraft(
            manifestJSON: manifestJSON().replacingOccurrences(of: "weather-tool", with: "create-plugin"),
            swiftSource: "import Foundation\nprint(\"[]\")"
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
        {"name":"weather-tool","version":"1.0.0","extensions":{"app.derrick":{"entrypoint":"./app.derrick/plugin.swift"}}}
        """
        do {
            _ = try await PluginFactory().build(
                draft: PluginFactoryDraft(
                    manifestJSON: manifest,
                    swiftSource: "import Foundation\nprint(\"[]\")"
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
            swiftSource: "import Foundation\nprint(\"[]\")"
        )
        let draft = try response.draft()
        let manifest = try AgentPluginManifest.decode(Data(draft.manifestJSON.utf8))
        #expect(manifest.schema == PluginContract.agentPluginSchema)
        #expect(manifest.derrick?.entrypoint == "./app.derrick/plugin.swift")
    }

    @Test func builderNormalizesUnderscorePluginIDAndWritesSecretLabels() throws {
        let response = PluginFactoryBuilderResponse(
            pluginID: "slack_connection",
            version: "1.0.0",
            description: "Slack send and receive.",
            swiftSource: "import Foundation\nprint(\"[]\")",
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

    @Test func invalidManifestIsBuilderCorrectable() {
        #expect(PluginFactoryError.invalidManifest("Invalid plugin id 'slack_connection'.").isBuilderCorrectable)
    }

    @Test func builderRejectsInvalidSkillPathBeforeFactoryExecution() {
        let response = PluginFactoryBuilderResponse(
            pluginID: "weather-tool",
            version: "1.0.0",
            description: "Weather summaries.",
            swiftSource: "import Foundation\nprint(\"[]\")",
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
            swiftSource: "import Foundation\nprint(\"[]\")",
            testInput: Data(#"{"kind":"manual"}"#.utf8)
        )
    }

    private func manifestJSON() -> String {
        """
        {"$schema":"\(PluginContract.agentPluginSchema)","name":"weather-tool","version":"1.2.3","extensions":{"app.derrick":{"entrypoint":"./app.derrick/plugin.swift"}}}
        """
    }
}

private actor RecordingFactoryExecutor: PluginFactoryExecutor {
    let draftResult: PluginFactoryExecutionResult
    let firstDraftResult: PluginFactoryExecutionResult?
    private(set) var draftRunCount = 0
    private(set) var compileCount = 0
    private(set) var compiledRunCount = 0

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

    func runSwiftFile(source: String, input: Data) async throws -> PluginFactoryExecutionResult {
        _ = source
        _ = input
        draftRunCount += 1
        return draftRunCount == 1 ? (firstDraftResult ?? draftResult) : draftResult
    }

    func compileSwiftFile(source: String) async throws -> Data {
        _ = source
        compileCount += 1
        return Data("compiled-swift-binary".utf8)
    }

    func runCompiledArtifact(_ artifact: Data, input: Data) async throws -> PluginFactoryExecutionResult {
        _ = artifact
        _ = input
        compiledRunCount += 1
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
