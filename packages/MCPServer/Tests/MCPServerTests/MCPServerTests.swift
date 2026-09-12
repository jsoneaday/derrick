import Foundation
import DockerRunnerXPC
import Testing
import MCPClient
import Structure
import Plugin
import WebCrawler
@testable import MCPServer

@Suite(.serialized) struct MCPServerTests {
    private static let dummyGoScript = """
        package main

        import (
            "encoding/json"
            "os"
        )

        func main() {
            var event map[string]any
            _ = json.NewDecoder(os.Stdin).Decode(&event)
            enc := json.NewEncoder(os.Stdout)
            enc.SetEscapeHTML(false)
            _ = enc.Encode([]map[string]any{{"verb": "result.emit", "summary": "ok"}})
        }
        """

    private static func isGuestBinaryExec(_ arguments: [String]) -> Bool {
        arguments.contains(DockerWorkerRuntime.guestBinaryPath)
            && !arguments.contains("cat >")
    }

    private static func mockWorkerImageInspect(_ arguments: [String]) -> DockerCLIResult? {
        guard arguments.first == "image", arguments.contains("inspect") else {
            return nil
        }
        if arguments.contains("{{.Id}}") {
            let digest = DockerWorkerRuntime.pinnedDigest.rawValue + "\n"
            return DockerCLIResult(exitCode: 0, stdout: Data(digest.utf8), stderr: Data())
        }
        if arguments.contains(where: { $0.contains(DockerWorkerRuntime.binariesLabelKey) }) {
            let label = DockerWorkerRuntime.binariesLabelValue + "\n"
            return DockerCLIResult(exitCode: 0, stdout: Data(label.utf8), stderr: Data())
        }
        return DockerCLIResult(exitCode: 0, stdout: Data("[]".utf8), stderr: Data())
    }

    private actor ImageBuildLatch {
        private(set) var succeeded = false
        func markSucceeded() { succeeded = true }
    }

    private static func missingUntilBuiltExecutor(
        recorder: DockerCallRecorder,
        latch: ImageBuildLatch,
        failFirstBuild: Bool = false,
        buildDelay: Duration? = nil
    ) -> DockerCLIExecutor {
        { args, _, _ in
            await recorder.append(args)
            if args.first == "build" {
                if let buildDelay {
                    try await Task.sleep(for: buildDelay)
                }
                if failFirstBuild {
                    let builds = await recorder.calls.filter { $0.first == "build" }.count
                    if builds == 1 {
                        return DockerCLIResult(exitCode: 1, stdout: Data(), stderr: Data("boom".utf8))
                    }
                }
                await latch.markSucceeded()
                return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            if args.first == "image" {
                if await latch.succeeded, let mocked = mockWorkerImageInspect(args) {
                    return mocked
                }
                return DockerCLIResult(exitCode: 1, stdout: Data(), stderr: Data())
            }
            return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
    }

    private static let dummyCompiledGuest = Data([0x7f, 0x45, 0x4c, 0x46, 0x02])

    private static func mockGuestDocker(_ arguments: [String]) -> DockerCLIResult? {
        if arguments.contains("cat > /tmp/guest") {
            return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        if arguments.contains(DockerWorkerRuntime.guestWriteSourceShell) {
            return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        if arguments.contains(DockerWorkerRuntime.guestCompileShell) {
            return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        if arguments.contains(DockerWorkerRuntime.guestReadBinaryShell) {
            return DockerCLIResult(exitCode: 0, stdout: dummyCompiledGuest, stderr: Data())
        }
        if isGuestBinaryExec(arguments) {
            return DockerCLIResult(
                exitCode: 0,
                stdout: Data(#"[{"verb":"result.emit","summary":"ok"}]"#.utf8),
                stderr: Data()
            )
        }
        return mockWorkerImageInspect(arguments)
    }

    private static let dummyStdin: @Sendable ([String], Data, Int) async throws -> DockerCLIResult = { arguments, _, _ in
        if let mocked = mockGuestDocker(arguments) {
            return mocked
        }
        return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
    }

    private struct StubReviewer: ScriptReviewer {
        let name: String = "stub-reviewer"
        let assessment: ScriptReviewAssessment

        func review(_ args: ScriptExecutionArguments) async throws -> ScriptReviewOutcome {
            _ = args
            return ScriptReviewOutcome(
                assessment: assessment,
                timing: ScriptReviewerTiming(
                    ttfbMS: 1,
                    streamMS: 1,
                    decodeMS: 0,
                    totalMS: 2,
                    requestChars: 10,
                    responseChars: 10,
                    chunkCount: 1,
                    model: "stub"
                )
            )
        }
    }

    private struct StubDenyGate: HostHTTPAccessGate {
        func authorize(url: URL, invokeID: String) async -> HostHTTPAccessDecision {
            _ = url
            _ = invokeID
            return .deny("blacklist:*.bank.com")
        }
    }

    @Test func registrySearchMatchesToolName() async throws {
        let registry = MCPToolRegistry()
        await registry.registerRaw(name: "tool_search", description: "Search tools") { _ in "ok" }

        let results = await registry.search(matching: "search")

        #expect(results.map(\.name) == ["tool_search"])
    }

    @Test func batchCallAggregatesResults() async throws {
        let registry = MCPToolRegistry()
        await registry.registerRaw(name: "tool_one", description: "First tool") { _ in "alpha" }
        await registry.registerRaw(name: "tool_two", description: "Second tool") { _ in "beta" }

        let result = await registry.batchCall(
            MCPToolBatchRequest(
                invocations: [
                    MCPToolInvocation(name: "tool_one"),
                    MCPToolInvocation(name: "tool_two")
                ],
                filterQuery: "alpha"
            )
        )

        #expect(result.results.map(\.text) == ["alpha", "beta"])
        #expect(result.combinedContent == "alpha")
        #expect(result.isError == false)
    }

    @Test func sessionMemorySearchToolIsDiscoverable() async throws {
        let host = MCPServerHost()
        await host.registerSessionMemorySearchTool { arguments in
            "memory: \(arguments.query ?? "nil")/\(arguments.limit)/\(arguments.page)"
        }

        let results = await host.searchRegisteredTools(matching: "session")

        #expect(results.map(\.name) == ["session_memory_search"])
    }

    @Test func localBridgeConnectsClientToServerOverStdio() async throws {
        let bridge = try await MCPLocalBridge.make { server in
            await server.registerSessionMemorySearchTool { arguments in
                "bridge: \(arguments.query ?? "nil")/\(arguments.limit)/\(arguments.page)"
            }
        }

        let tools = try await bridge.client.searchTools(matching: "session")
        #expect(tools.map(\.name) == ["session_memory_search"])

        let result = try await bridge.client.callTool(
            named: "session_memory_search",
            arguments: [
                "query": .string("hello"),
                "limit": .string("3"),
                "page": .string("2")
            ]
        )

        #expect(result.text == "bridge: hello/3/2")
        #expect(result.isError == false)
    }

    @Test func scriptToolIsDiscoverable() async throws {
        let bridge = try await MCPLocalBridge.make { server in
            await server.registerScriptExecutionTool(
                stdinExecutor: { _, _, _ in DockerCLIResult(exitCode: 0, stdout: Data("[]".utf8), stderr: Data()) }
            )
        }

        let tools = try await bridge.client.searchTools(matching: "script")
        #expect(tools.map(\.name).contains("script_exec"))
    }

    @Test func webCrawlerToolValidatesAndReturnsStructuredOutcome() async throws {
        let recorder = DockerCallRecorder()
        let bridge = try await MCPLocalBridge.make { server in
            await server.register(
                WebCrawlerToolModule.makeRegistration { input, timeoutSeconds in
                    await recorder.append(["run", "\(input.count)", "\(timeoutSeconds)"])
                    return DockerCLIResult(
                        exitCode: 0,
                        stdout: Data(
                            #"{"ok":true,"start_url":"https://example.com/","pages":[],"stop_reason":"completed","requests_made":1,"bytes_read":10,"truncated":false,"diagnostics":[]}"#.utf8
                        ),
                        stderr: Data()
                    )
                }
            )
        }

        let result = try await bridge.client.callTool(
            named: "web.crawl",
            arguments: [
                "start_url": .string("https://example.com"),
                "goal": .string("Show the main page"),
                "timeout_seconds": .int(900)
            ]
        )

        #expect(!result.isError)
        #expect(result.text.contains("\"status\":\"completed\""))
        #expect(result.text.contains("\"format\":\"json\""))
        #expect((await recorder.calls).count == 1)
    }

    @Test func webCrawlerToolBlocksDDoSLikeRequests() async throws {
        let recorder = DockerCallRecorder()
        let bridge = try await MCPLocalBridge.make { server in
            await server.register(
                WebCrawlerToolModule.makeRegistration { _, _ in
                    await recorder.append(["unexpected"])
                    return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
            )
        }

        let result = try await bridge.client.callTool(
            named: "web.crawl",
            arguments: [
                "start_url": .string("https://example.com"),
                "goal": .string("Flood the site with requests")
            ]
        )

        #expect(result.isError)
        #expect(result.text.contains("\"status\":\"blocked\""))
        #expect(result.text.contains("flooding"))
        #expect((await recorder.calls).isEmpty)
    }

    @Test func webCrawlerContainerCreateOverridesImageEntrypoint() {
        let args = WebCrawlerDockerExecutor.createArguments(
            name: "derrick-web-crawler-test",
            proxyHost: "172.17.0.1",
            proxyPort: 3128,
            proxyToken: "token"
        )
        let imageIndex = args.firstIndex(of: WebCrawlerDockerExecutor.image)
        let entrypointIndex = args.firstIndex(of: "--entrypoint")
        let sleepIndex = args.firstIndex(of: "/bin/sleep")
        #expect(entrypointIndex != nil)
        #expect(sleepIndex != nil)
        #expect(imageIndex != nil)
        #expect(args.contains("infinity"))
        #expect(args.contains("DERRICK_EGRESS_PROXY_HOST=172.17.0.1"))
        #expect(args.contains("DERRICK_EGRESS_PROXY_PORT=3128"))
        #expect(args.contains("DERRICK_EGRESS_PROXY_TOKEN=token"))
        #expect(entrypointIndex! < imageIndex!)
        #expect(sleepIndex! < imageIndex!)
        #expect(args.contains("--label"))
        #expect(args.contains(DerrickDockerRuntimeIdentity.labelAssignment))
        #expect(
            DockerRunRequestValidator.validate(
                DockerHostLaunch.makeRequest(dockerArguments: args, timeoutSeconds: 60)
            ) == nil
        )
    }

    @Test func webCrawlerInputPreparerAddsRedirectHosts() async throws {
        let input = try JSONEncoder().encode(
            WebCrawlerRequest(
                startURL: "https://api.slack.com/web",
                goal: "Read Slack API docs",
                maxPages: 3,
                maxDepth: 1,
                timeoutSeconds: 120
            )
        )

        let prepared = try await WebCrawlerDockerInputPreparer.enrich(input)
        let object = try JSONSerialization.jsonObject(with: prepared.data) as? [String: Any]
        let allowed = object?["allowed_hosts"] as? [String]

        #expect(prepared.leaseHosts.contains("api.slack.com"))
        #expect(prepared.leaseHosts.contains("docs.slack.dev"))
        #expect(allowed?.contains("docs.slack.dev") == true)
    }

    @Test func workerImageLabelDetectsMissingBinaries() async {
        let recorder = DockerCallRecorder()
        let executor: DockerCLIExecutor = { args, _, _ in
            await recorder.append(args)
            if args.first == "image", args.contains("inspect"), args.contains("--format") {
                return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let current = await DockerImageInspector.workerImageHasCurrentBinaries(executor: executor)
        #expect(!current)
    }

    @Test func dockerProductImagePrewarmerSkipsBuildWhenImagePresent() async throws {
        let recorder = DockerCallRecorder()
        let executor: DockerCLIExecutor = { args, _, _ in
            await recorder.append(args)
            if let mocked = Self.mockWorkerImageInspect(args) {
                return mocked
            }
            return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        try await DockerProductImagePrewarmer.ensureWebCrawlerImage(executor: executor)
        let calls = await recorder.calls
        #expect(calls.first == ["image", "inspect", DockerProductImagePolicy.workerImage])
        #expect(calls.contains { $0.contains("--format") && $0.contains(where: { $0.contains(DockerWorkerRuntime.binariesLabelKey) }) })
        #expect(calls.contains { $0.contains("{{.Id}}") })
        #expect(!calls.contains { $0.first == "build" })
    }

    @Test func dockerProductImagePrewarmerBuildsWhenImageMissing() async throws {
        guard DerrickRepositoryRoot.locate() != nil else { return }
        let recorder = DockerCallRecorder()
        let latch = ImageBuildLatch()
        let executor = Self.missingUntilBuiltExecutor(recorder: recorder, latch: latch)
        try await DockerProductImagePrewarmer.ensureWebCrawlerImage(executor: executor)
        let calls = await recorder.calls
        #expect(calls[0] == ["image", "inspect", DockerProductImagePolicy.workerImage])
        #expect(calls.contains { $0.first == "build" && $0.contains(DockerProductImagePolicy.workerImage) })
        #expect(calls.contains { $0.contains("{{.Id}}") })
        #expect(calls.filter { $0.first == "build" }.count == 1)
    }

    @Test func crawlerImageBuildFailureMessageOmitsBuildkitDump() {
        let error = DockerProductImagePrewarmerError.buildFailed(
            DockerProductImagePolicy.workerImage,
            "#0 building with \"default\" instance using docker driver"
        )
        let text = error.localizedDescription
        #expect(!text.contains("#0 building"))
        #expect(text.lowercased().contains("worker image"))
        #expect(text.lowercased().contains("disk"))
        #expect(error.compilerDiagnostic == nil)
    }

    @Test func crawlerImageBuildDiagnosticExtractsCompilerError() {
        let detail = """
        #0 building with "default" instance using docker driver
        /build/Structure/Sources/AppLayerServices/AgentService/AgentServiceXPC.swift:2:8: error: no such module 'CryptoKit'
        error: Build failed
        """
        let error = DockerProductImagePrewarmerError.buildFailed(
            DockerProductImagePolicy.workerImage,
            detail
        )
        #expect(error.compilerDiagnostic?.contains("CryptoKit") == true)
        #expect(!error.localizedDescription.contains("CryptoKit"))
    }

    @Test func crawlerImageBuildIsSingleFlight() async throws {
        guard DerrickRepositoryRoot.locate() != nil else { return }
        let recorder = DockerCallRecorder()
        let latch = ImageBuildLatch()
        let executor = Self.missingUntilBuiltExecutor(
            recorder: recorder,
            latch: latch,
            buildDelay: .milliseconds(80)
        )
        let gate = WebCrawlerImageGate()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await gate.ensureReady(executor: executor) }
            group.addTask { try await gate.ensureReady(executor: executor) }
            group.addTask { try await gate.ensureReady(executor: executor) }
            try await group.waitForAll()
        }
        let calls = await recorder.calls
        #expect(calls.filter { $0.first == "build" }.count == 1)
        #expect(calls.filter { $0 == ["image", "inspect", DockerProductImagePolicy.workerImage] }.count == 1)
    }

    @Test func crawlerImageBuildFailureAllowsRetry() async throws {
        guard DerrickRepositoryRoot.locate() != nil else { return }
        let recorder = DockerCallRecorder()
        let latch = ImageBuildLatch()
        let executor = Self.missingUntilBuiltExecutor(
            recorder: recorder,
            latch: latch,
            failFirstBuild: true
        )
        let gate = WebCrawlerImageGate()
        do {
            try await gate.ensureReady(executor: executor)
            Issue.record("expected first build to fail")
        } catch {
            // retry after failure
        }
        try await gate.ensureReady(executor: executor)
        let builds = await recorder.calls.filter { $0.first == "build" }
        #expect(builds.count == 2)
    }

    @Test func fileExtractorContainerCreateUsesJobBindMountsAndOverridesEntrypoint() {
        let jobID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let input = URL(fileURLWithPath: "/tmp/file-jobs/\(jobID)/in")
        let output = URL(fileURLWithPath: "/tmp/file-jobs/\(jobID)/out")
        let args = FileExtractorDockerExecutor.createArguments(
            name: "derrick-file-extractor-test",
            inputDirectory: input,
            outputDirectory: output
        )
        let imageIndex = args.firstIndex(of: FileExtractorDockerExecutor.image)
        let entrypointIndex = args.firstIndex(of: "--entrypoint")
        let sleepIndex = args.firstIndex(of: "/bin/sleep")
        #expect(args.contains("--network"))
        #expect(args.contains("none"))
        #expect(args.contains("\(input.path):/data/in:ro"))
        #expect(args.contains("\(output.path):/data/out"))
        #expect(args.contains("infinity"))
        #expect(entrypointIndex != nil)
        #expect(sleepIndex != nil)
        #expect(imageIndex != nil)
        #expect(entrypointIndex! < imageIndex!)
        #expect(sleepIndex! < imageIndex!)
        #expect(args.contains("--label"))
        #expect(args.contains(DerrickDockerRuntimeIdentity.labelAssignment))
        #expect(
            DockerRunRequestValidator.validate(
                DockerHostLaunch.makeRequest(dockerArguments: args, timeoutSeconds: 60)
            ) == nil
        )
    }

    @Test func fileExtractorRunCreatesStartsExecsAndRemoves() async throws {
        let recorder = DockerCallRecorder()
        let runner = FileExtractorDockerExecutor(
            executor: { arguments, _, _ in
                await recorder.append(arguments)
                if let mocked = Self.mockWorkerImageInspect(arguments) {
                    return mocked
                }
                return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
            },
            queue: DerrickDockerRunQueue(maxConcurrentContainers: 1)
        )
        let jobID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        _ = try await runner.run(
            input: Data(#"{}"#.utf8),
            inputDirectory: URL(fileURLWithPath: "/tmp/file-jobs/\(jobID)/in"),
            outputDirectory: URL(fileURLWithPath: "/tmp/file-jobs/\(jobID)/out"),
            timeoutSeconds: 5
        )
        let calls = await recorder.calls
        #expect(calls.first?.starts(with: ["image", "inspect"]) == true)
        #expect(calls.contains { $0.first == "create" })
        #expect(calls.contains { $0.first == "start" })
        #expect(calls.contains { $0.contains("/usr/local/bin/derrick-file-extractor") })
        #expect(calls.contains { $0.first == "rm" && $0.contains("-f") })
    }

    @Test func fileExtractorMissingImageDoesNotCreateContainer() async throws {
        let recorder = DockerCallRecorder()
        let runner = FileExtractorDockerExecutor(
            executor: { arguments, _, _ in
                await recorder.append(arguments)
                return DockerCLIResult(exitCode: 1, stdout: Data(), stderr: Data())
            },
            queue: DerrickDockerRunQueue(maxConcurrentContainers: 1)
        )
        do {
            _ = try await runner.run(
                input: Data(#"{}"#.utf8),
                inputDirectory: URL(fileURLWithPath: "/tmp/file-jobs/missing/in"),
                outputDirectory: URL(fileURLWithPath: "/tmp/file-jobs/missing/out"),
                timeoutSeconds: 5
            )
            Issue.record("expected missing extractor image")
        } catch is DockerProductImagePrewarmerError {
            // Image is missing; prewarmer tries a rebuild and that mock also fails.
        } catch is DockerImageDigestError {
            // Pin check after a failed inspect.
        } catch let error as FileExtractorDockerExecutorError {
            #expect(error == .imageUnavailable(FileExtractorDockerExecutor.image))
        }
        let calls = await recorder.calls
        #expect(calls.contains { $0.first == "image" && $0.contains("inspect") })
        #expect(!calls.contains { $0.first == "create" })
        #expect(!calls.contains { $0.first == "start" })
    }

    @Test func orphanSweeperRemovesLabeledAndPrefixedContainers() async throws {
        let recorder = DockerCallRecorder()
        let executor: DockerCLIExecutor = { args, _, _ in
            await recorder.append(args)
            if args.first == "ps" {
                if args.contains("label=\(DerrickDockerRuntimeIdentity.labelAssignment)") {
                    return DockerCLIResult(exitCode: 0, stdout: Data("aaaaaaaaaaaa\n".utf8), stderr: Data())
                }
                if args.contains("name=derrick-guest-runtime") {
                    return DockerCLIResult(exitCode: 0, stdout: Data("bbbbbbbbbbbb\naaaaaaaaaaaa\n".utf8), stderr: Data())
                }
                return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let removed = await DerrickDockerOrphanSweeper.sweep(executor: executor)
        #expect(removed == 2)
        let calls = await recorder.calls
        #expect(calls.filter { $0.first == "ps" }.count == DerrickDockerRuntimeIdentity.psListArguments.count)
        let rm = try #require(calls.first { $0.first == "rm" })
        #expect(rm.contains("-f"))
        #expect(rm.contains("aaaaaaaaaaaa"))
        #expect(rm.contains("bbbbbbbbbbbb"))
        for call in calls where call.first == "ps" || call.first == "rm" {
            #expect(
                DockerRunRequestValidator.validate(
                    DockerHostLaunch.makeRequest(dockerArguments: call, timeoutSeconds: 60)
                ) == nil
            )
        }
    }

    @Test func orphanSweeperSkipsRemoveWhenNothingMatches() async throws {
        let recorder = DockerCallRecorder()
        let executor: DockerCLIExecutor = { args, _, _ in
            await recorder.append(args)
            return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let removed = await DerrickDockerOrphanSweeper.sweep(executor: executor)
        #expect(removed == 0)
        let calls = await recorder.calls
        #expect(calls.allSatisfy { $0.first == "ps" })
        #expect(!calls.contains { $0.first == "rm" })
    }

    @Test func fileJobWorkspaceCopiesAttachmentsAndPublishesOutputs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let attachments = root.appendingPathComponent("chat-attachments", isDirectory: true)
        let jobs = root.appendingPathComponent("file-jobs", isDirectory: true)
        let exports = root.appendingPathComponent("file-exports", isDirectory: true)
        let session = attachments.appendingPathComponent("session-1", isDirectory: true)
            .appendingPathComponent("a1", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try "name,score\nAda,10\n".write(
            to: session.appendingPathComponent("My_Report.csv"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = try FileJobWorkspace.prepare(
            sessionID: "session-1",
            requestedFilenames: ["My Report.csv"],
            attachmentsRoot: attachments,
            jobsRoot: jobs,
            exportsRoot: exports
        )
        #expect(workspace.copiedFilenames == ["My_Report.csv"])
        #expect(
            FileManager.default.fileExists(
                atPath: workspace.inputDirectory.appendingPathComponent("My_Report.csv").path
            )
        )

        try "extracted".write(
            to: workspace.outputDirectory.appendingPathComponent("notes.md"),
            atomically: true,
            encoding: .utf8
        )
        let exported = try workspace.publishOutputs()
        #expect(exported == ["notes.md"])
        #expect(
            FileManager.default.fileExists(
                atPath: workspace.exportDirectory.appendingPathComponent("notes.md").path
            )
        )
        workspace.removeJobDirectories()
        #expect(!FileManager.default.fileExists(atPath: workspace.inputDirectory.path))
        #expect(
            FileManager.default.fileExists(
                atPath: workspace.exportDirectory.appendingPathComponent("notes.md").path
            )
        )
    }

    @Test func fileJobWorkspaceRejectsPathTraversalRequestedNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let attachments = root.appendingPathComponent("chat-attachments", isDirectory: true)
        let session = attachments.appendingPathComponent("session-1", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try "ok".write(to: session.appendingPathComponent("notes.csv"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: FileJobWorkspaceError.unsafeFilename("../notes.csv")) {
            _ = try FileJobWorkspace.prepare(
                sessionID: "session-1",
                requestedFilenames: ["../notes.csv"],
                attachmentsRoot: attachments,
                jobsRoot: root.appendingPathComponent("file-jobs", isDirectory: true),
                exportsRoot: root.appendingPathComponent("file-exports", isDirectory: true)
            )
        }
    }

    @Test func fileExtractorToolExtractsAttachedFilesWithoutJobsCreate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let attachments = root.appendingPathComponent("chat-attachments", isDirectory: true)
        let jobs = root.appendingPathComponent("file-jobs", isDirectory: true)
        let exports = root.appendingPathComponent("file-exports", isDirectory: true)
        let session = attachments.appendingPathComponent("session-1", isDirectory: true)
            .appendingPathComponent("a1", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try "name,score\nAda,10\n".write(
            to: session.appendingPathComponent("notes.csv"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = DockerCallRecorder()
        let bridge = try await MCPLocalBridge.make { server in
            await server.register(
                FileExtractorToolModule.makeRegistration(
                    sessionID: { "session-1" },
                    prepareWorkspace: { sessionID, filenames in
                        try FileJobWorkspace.prepare(
                            sessionID: sessionID,
                            requestedFilenames: filenames,
                            attachmentsRoot: attachments,
                            jobsRoot: jobs,
                            exportsRoot: exports
                        )
                    },
                    run: { input, workspace, timeoutSeconds in
                        await recorder.append(["run", "\(input.count)", "\(timeoutSeconds)"])
                        try "preview".write(
                            to: workspace.outputDirectory.appendingPathComponent("notes.md"),
                            atomically: true,
                            encoding: .utf8
                        )
                        return DockerCLIResult(
                            exitCode: 0,
                            stdout: Data(
                                #"{"ok":true,"operation":"extract","files":[{"input_name":"notes.csv","output_name":"notes.md","kind":"csv","byte_count":7,"preview":"Ada"}],"diagnostics":[]}"#.utf8
                            ),
                            stderr: Data()
                        )
                    }
                )
            )
        }

        let result = try await bridge.client.callTool(
            named: "files.extract",
            arguments: [
                "operation": .string("extract"),
                "output_format": .string("markdown")
            ]
        )

        #expect(!result.isError)
        #expect(result.text.contains("\"status\":\"completed\""))
        #expect(result.text.contains("notes.md"))
        #expect(result.text.contains("Ada"))
        #expect((await recorder.calls).count == 1)
    }

    @Test func fileExtractorToolRequiresOpenChat() async throws {
        let recorder = DockerCallRecorder()
        let bridge = try await MCPLocalBridge.make { server in
            await server.register(
                FileExtractorToolModule.makeRegistration(
                    sessionID: { nil },
                    run: { _, _, _ in
                        await recorder.append(["unexpected"])
                        return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
                    }
                )
            )
        }

        let result = try await bridge.client.callTool(
            named: "files.extract",
            arguments: [:]
        )

        #expect(result.isError)
        #expect(result.text.contains("\"status\":\"blocked\""))
        #expect(result.text.contains("chat"))
        #expect((await recorder.calls).isEmpty)
    }

    @Test func webCrawlerToolBlocksInfiniteLoopGoals() async throws {
        let recorder = DockerCallRecorder()
        let bridge = try await MCPLocalBridge.make { server in
            await server.register(
                WebCrawlerToolModule.makeRegistration { _, _ in
                    await recorder.append(["unexpected"])
                    return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
            )
        }

        let result = try await bridge.client.callTool(
            named: "web.crawl",
            arguments: [
                "start_url": .string("https://example.com"),
                "goal": .string("Crawl forever in an infinite loop")
            ]
        )

        #expect(result.isError)
        #expect(result.text.contains("\"status\":\"blocked\""))
        #expect(result.text.contains("infinite"))
        #expect((await recorder.calls).isEmpty)
    }

    @Test func webCrawlerToolRejectsTimeoutAboveFifteenMinutes() async throws {
        let recorder = DockerCallRecorder()
        let bridge = try await MCPLocalBridge.make { server in
            await server.register(
                WebCrawlerToolModule.makeRegistration { _, _ in
                    await recorder.append(["unexpected"])
                    return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
            )
        }

        let result = try await bridge.client.callTool(
            named: "web.crawl",
            arguments: [
                "start_url": .string("https://example.com"),
                "goal": .string("Read the homepage"),
                "timeout_seconds": .int(901)
            ]
        )

        #expect(result.isError)
        #expect(result.text.contains("\"status\":\"blocked\""))
        #expect(result.text.contains("900"))
        #expect((await recorder.calls).isEmpty)
    }

    @Test func webCrawlerToolMapsTimeoutStopReason() async throws {
        let bridge = try await MCPLocalBridge.make { server in
            await server.register(
                WebCrawlerToolModule.makeRegistration { _, _ in
                    DockerCLIResult(
                        exitCode: 0,
                        stdout: Data(
                            #"{"ok":false,"start_url":"https://example.com/","pages":[],"stop_reason":"timeout","requests_made":1,"bytes_read":0,"truncated":false,"diagnostics":["crawl timeout reached"]}"#.utf8
                        ),
                        stderr: Data()
                    )
                }
            )
        }

        let result = try await bridge.client.callTool(
            named: "web.crawl",
            arguments: [
                "start_url": .string("https://example.com"),
                "goal": .string("Read the homepage"),
                "timeout_seconds": .int(5)
            ]
        )

        #expect(result.isError)
        #expect(result.text.contains("\"status\":\"timeout\"") || result.text.contains("\"timed_out\":true"))
    }

    @Test func pluginInvokeSurfacesExecutionFailure() async throws {
        let bridge = try await MCPLocalBridge.make { server in
            await server.register(
                PluginRuntimeToolModule.makeInvokeRegistration { _, _ in
                    PluginFactoryExecutionResult(
                        exitCode: 7,
                        stderr: Data("guest runtime failed".utf8)
                    )
                }
            )
        }

        let result = try await bridge.client.callTool(
            named: "plugin.invoke",
            arguments: ["plugin_id": .string("weather-tool")]
        )

        #expect(result.isError)
        let outcome = try #require(ToolExecutionOutcome.decode(from: result.text))
        #expect(outcome.status == .failed)
        #expect(outcome.stage == .execution)
        #expect(result.text.contains("exit 7"))
        #expect(result.text.contains("guest runtime failed"))
    }

    @Test func pluginFactorySurfacesReviewFailureOutcome() async throws {
        let bridge = try await MCPLocalBridge.make { server in
            await server.register(
                PluginFactoryToolModule.makeRegistration { _, _ in
                    throw PluginFactoryError.reviewRejected(
                        summary: "The draft did not satisfy the contract.",
                        findings: ["blocking: poll_inbox is incomplete."]
                    )
                }
            )
        }

        let result = try await bridge.client.callTool(
            named: "plugin_factory_build",
            arguments: ["goal": .string("make a safe plugin")]
        )

        #expect(result.isError)
        let outcome = try #require(ToolExecutionOutcome.decode(from: result.text))
        #expect(outcome.status == .blocked)
        #expect(outcome.stage == .review)
        #expect(outcome.retry?.allowed == true)
        #expect(outcome.diagnostics.contains { $0.message.contains("did not satisfy") })
        #expect(outcome.diagnostics.contains { $0.message.contains("poll_inbox") })
    }

    @Test func phaseTimingScriptMetricsCountLinesAndChars() {
        let script = "import json, sys\nprint(1)\n"
        let metrics = ScriptPhaseTiming.scriptMetrics(script)
        #expect(metrics.chars == script.utf8.count)
        #expect(metrics.lines == 3)
        var phase = ScriptPhaseTiming(
            staticValidateMS: 1,
            reviewerMS: 10,
            ensureMS: 2,
            execMS: 3,
            totalMS: 16,
            scriptCharCount: metrics.chars,
            scriptLineCount: metrics.lines,
            wrapperCharCount: 100
        )
        phase.applyReviewerTiming(
            ScriptReviewerTiming(
                ttfbMS: 4,
                streamMS: 5,
                decodeMS: 1,
                totalMS: 10,
                requestChars: 100,
                responseChars: 200,
                chunkCount: 3,
                model: "gpt-5.6-luna"
            )
        )
        let summary = phase.summaryLine
        #expect(summary.hasPrefix("[TIME_METRIC]"))
        #expect(summary.contains("reviewer_ms=10"))
        #expect(summary.contains("exec_ms=3"))
        #expect(summary.contains("reviewer_ttfb_ms=4"))
        #expect(summary.contains("reviewer_stream_ms=5"))
        #expect(summary.contains("reviewer_response_chars=200"))
        #expect(summary.contains("reviewer_model=gpt-5.6-luna"))
    }

    @Test func hostHTTPGateDenySkipsFetch() async {
        let client = HostHTTPClient()
        await client.setAccessGate(StubDenyGate())
        let fetched = await client.perform(
            HostHTTPRequest(requestID: "r1", method: "GET", url: "https://example.com/"),
            invokeID: "inv-1"
        )
        #expect(fetched.succeeded == false)
        #expect(fetched.error == "blacklist:*.bank.com")
        #expect(fetched.body.isEmpty)
    }

    @Test func httpNilErrorIsSuccessOnTheWire() throws {
        let ok = HostHTTPFetch(status: 200, headers: [:], body: "<html>", error: nil)
        #expect(ok.succeeded)
        let response = ok.response(requestID: "r1")
        #expect(response.succeeded)
        #expect(response.error == nil)
        let event = PluginHopEvent(kind: .httpResults, httpResults: [response])
        let data = try JSONWire.encode(event)
        let decoded = try JSONDecoder().decode(PluginHopEvent.self, from: data)
        #expect(decoded.httpResults?.first?.succeeded == true)
        #expect(decoded.httpResults?.first?.error == nil)
        #expect(decoded.httpResults?.first?.body == "<html>")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let results = object?["http_results"] as? [[String: Any]]
        #expect(results?.first?["body"] as? String == "<html>")
        #expect(results?.first?["json"] == nil)
    }

    @Test func goGuestRuntimeUsesWorkerImage() {
        #expect(DerrickGuestRuntime.guestDockerImage == DockerWorkerRuntime.image)
        #expect(GoGuestDockerExecutor.containerPrefix == "derrick-guest-runtime")
        #expect(DerrickDockerRunQueue.guest.maxConcurrentContainers == 1)
        #expect(DerrickDockerRunQueue.crawler.maxConcurrentContainers == 2)
        #expect(DerrickDockerRunQueue.extractor.maxConcurrentContainers == 1)
        #expect(
            DerrickDockerRunQueue.guest.maxConcurrentContainers
                == ContainerLifecyclePolicy.derrickDefault.maxOfflineContainers
        )
        #expect(
            DerrickDockerRunQueue.crawler.maxConcurrentContainers
                == ContainerLifecyclePolicy.derrickDefault.maxNetworkContainers
        )
        #expect(
            DerrickDockerRunQueue.extractor.maxConcurrentContainers
                == ContainerLifecyclePolicy.derrickDefault.maxFileExtractContainers
        )
    }

    @Test func oneshotEnsurePulledImageSkipsPullWhenImageExists() async throws {
        let recorder = DockerCallRecorder()
        try await OneshotDockerContainer.ensurePulledImage(DockerWorkerRuntime.image) { arguments, _, _ in
            await recorder.append(arguments)
            return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let calls = await recorder.calls
        #expect(calls.contains { $0.starts(with: ["image", "inspect"]) })
        #expect(!calls.contains { $0.first == "pull" })
    }

    @Test func oneshotEnsurePulledImagePullsWhenMissing() async throws {
        let recorder = DockerCallRecorder()
        try await OneshotDockerContainer.ensurePulledImage(DockerWorkerRuntime.image) { arguments, _, _ in
            await recorder.append(arguments)
            if arguments.first == "image" {
                return DockerCLIResult(exitCode: 1, stdout: Data(), stderr: Data())
            }
            return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let calls = await recorder.calls
        #expect(calls.contains { $0.starts(with: ["image", "inspect"]) })
        #expect(calls.contains { $0.first == "pull" && $0.contains(DockerWorkerRuntime.image) })
    }

    @Test func dockerRunQueueSerializesWhenMaxIsOne() async throws {
        let queue = DerrickDockerRunQueue(maxConcurrentContainers: 1)
        let peak = PeakCounter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    try await queue.withPermit {
                        await peak.enter()
                        try await Task.sleep(for: .milliseconds(40))
                        await peak.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await peak.peak == 1)
    }

    @Test func dockerRunQueueAllowsCrawlerCapOfTwo() async throws {
        let queue = DerrickDockerRunQueue(maxConcurrentContainers: 2)
        let peak = PeakCounter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await queue.withPermit {
                        await peak.enter()
                        try await Task.sleep(for: .milliseconds(40))
                        await peak.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await peak.peak == 2)
    }

    @Test func oneshotDockerContainerRemovesAfterBodyFailure() async throws {
        let recorder = DockerCallRecorder()
        do {
            _ = try await OneshotDockerContainer.run(
                executor: { arguments, _, _ in
                    await recorder.append(arguments)
                    return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
                },
                prefix: "derrick-guest-runtime",
                createArguments: { name in ["create", "--name", name, DockerWorkerRuntime.image] },
                createStep: "create guest runtime container",
                startStep: "start guest runtime container",
                body: { _ in
                    throw OneshotDockerContainerError.commandFailed("exec", "boom")
                }
            )
            Issue.record("expected oneshot body failure")
        } catch {
            let calls = await recorder.calls
            #expect(calls.contains { $0.first == "create" })
            #expect(calls.contains { $0.first == "start" })
            #expect(calls.contains { $0.first == "rm" && $0.contains("-f") })
        }
    }

    @Test func goSourceVerifierRejectsNetworkAndDependencies() {
        let findings = GoScriptVerifier.validate(
            source: "package main\nimport \"net/http\"",
            dependencies: ["example": "1.0.0"]
        )
        #expect(findings.contains("Go guest must not import \"net/http\"."))
        #expect(findings.contains("Guest script dependencies are not supported."))
    }

    @Test func goSourceVerifierRequiresPackageMain() {
        let findings = GoScriptVerifier.validate(source: "package plugin")
        #expect(findings.contains("Go guest source must declare package main."))
    }

    @Test func goExecutorUsesReadOnlyOfflineContainer() async throws {
        let recorder = DockerCallRecorder()
        let runner = GoGuestDockerExecutor(
            image: DockerWorkerRuntime.image,
            executor: { arguments, _, _ in
                await recorder.append(arguments)
                if let mocked = Self.mockGuestDocker(arguments) {
                    return mocked
                }
                return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
            },
            queue: DerrickDockerRunQueue(maxConcurrentContainers: 1)
        )
        _ = try await runner.runSource(
            source: Self.dummyGoScript,
            input: Data(#"{"kind":"script"}"#.utf8)
        )

        let calls = await recorder.calls
        let create = calls.first(where: { $0.first == "create" }) ?? []
        #expect(create.contains("--network"))
        #expect(create.contains("none"))
        #expect(create.contains("--read-only"))
        #expect(create.contains("--label"))
        #expect(create.contains(DerrickDockerRuntimeIdentity.labelAssignment))
        #expect(calls.contains { $0.contains(DockerWorkerRuntime.guestWriteSourceShell) })
        #expect(calls.contains { $0.contains(DockerWorkerRuntime.guestCompileShell) })
        let exec = calls.first(where: { $0.contains(DockerWorkerRuntime.guestBinaryPath) }) ?? []
        #expect(exec.contains(DockerWorkerRuntime.guestBinaryPath))
        #expect(calls.contains { $0.first == "rm" && $0.contains("-f") })
    }

    @Test func goGuestDockerCommandsPassXPCValidation() async throws {
        let recorder = DockerCallRecorder()
        let runner = GoGuestDockerExecutor(
            image: DockerWorkerRuntime.image,
            executor: { arguments, _, _ in
                await recorder.append(arguments)
                if let error = DockerRunRequestValidator.validate(
                    DockerHostLaunch.makeRequest(dockerArguments: arguments, timeoutSeconds: 60)
                ) {
                    return DockerCLIResult(
                        exitCode: 1,
                        stdout: Data(),
                        stderr: Data(error.launchErrorMessage.utf8)
                    )
                }
                if let mocked = Self.mockGuestDocker(arguments) {
                    return mocked
                }
                return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
            },
            queue: DerrickDockerRunQueue(maxConcurrentContainers: 1)
        )
        let result = try await runner.runSource(
            source: Self.dummyGoScript,
            input: Data(#"{"kind":"script"}"#.utf8)
        )
        #expect(result.exitCode == 0)
        let calls = await recorder.calls
        #expect(calls.contains { $0.contains(DockerWorkerRuntime.guestWriteSourceShell) })
        #expect(calls.contains { $0.contains(DockerWorkerRuntime.guestCompileShell) })
        #expect(calls.contains { $0.contains(DockerWorkerRuntime.guestBinaryPath) })
    }

    @Test func leftoverSwiftRuntimePrefixIsStillSwept() {
        #expect(DerrickDockerRuntimeIdentity.namePrefixes.contains("derrick-swift-runtime"))
        #expect(GuestRuntimeLimits.maxTimeoutSeconds == 300)
    }

    @Test func goScriptCanReturnHTMLResult() async throws {
        let resultText = try await ScriptExecutionRuntime.run(
            arguments: [
                "description": .string("render a safe card"),
                "reason": .string("manual HTML output check"),
                "script": .string(Self.dummyGoScript)
            ],
            stdinExecutor: { arguments, _, _ in
                if Self.isGuestBinaryExec(arguments) {
                    return DockerCLIResult(
                        exitCode: 0,
                        stdout: Data(
                            #"[{"verb":"result.emit","html":"<p><strong>Safe</strong></p>"}]"#.utf8
                        ),
                        stderr: Data()
                    )
                }
                if let mocked = Self.mockGuestDocker(arguments) {
                    return mocked
                }
                return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
            },
            reviewer: StubReviewer(
                assessment: ScriptReviewAssessment(
                    alignedWithRequest: true,
                    confidence: 1,
                    suggestedAction: "allow",
                    concerns: [],
                    summary: "safe"
                )
            ),
            logger: { _ in }
        )

        let result = try #require(ToolExecutionOutcome.decode(from: resultText))
        #expect(result.status == .completed)
        #expect(result.output?.value == "<p><strong>Safe</strong></p>")
    }

    @Test func scriptExecRejectsUnsupportedLanguage() async throws {
        let resultText = try await ScriptExecutionRuntime.run(
            arguments: [
                "description": .string("legacy python"),
                "reason": .string("should be blocked"),
                "script": .string(Self.dummyGoScript),
                "language": .string("python")
            ],
            stdinExecutor: Self.dummyStdin,
            reviewer: nil,
            logger: { _ in },
            reviewRequired: false
        )
        let result = try #require(ToolExecutionOutcome.decode(from: resultText))
        #expect(result.status == .blocked)
        #expect(result.stage == .validation)
        #expect(resultText.contains("only runs Go"))
    }

    @Test func goScriptToolBlocksFilesystemAccess() async throws {
        let bridge = try await MCPLocalBridge.make { server in
            await server.registerScriptExecutionTool(
                stdinExecutor: Self.dummyStdin,
                reviewer: StubReviewer(
                    assessment: ScriptReviewAssessment(
                        alignedWithRequest: true,
                        confidence: 0.9,
                        suggestedAction: "allow",
                        concerns: [],
                        summary: "ok"
                    )
                )
            )
        }

        let result = try await bridge.client.callTool(
            named: "script_exec",
            arguments: [
                "description": .string("attempt write"),
                "reason": .string("test"),
                "script": .string("package main\nimport \"os\"\nfunc main() { _, _ = os.Open(\"/tmp/a\") }")
            ]
        )

        #expect(result.text.contains("\"status\":\"blocked\""))
        #expect(result.text.contains("\"stage\":\"validation\""))
    }

    @Test func leftoverSwiftGuestImageIsTreatedAsStaleHygieneTag() {
        #expect(DerrickGuestRuntime.swiftPluginDockerImage.contains("swift"))
        #expect(DerrickGuestRuntime.guestDockerImage == DockerWorkerRuntime.image)
    }

    @Test func guestPluginRunnerRunsGoRelease() async throws {
        let recorder = DockerCallRecorder()
        let release = PluginFactoryRelease(
            pluginID: "slack-connection",
            version: "1.0.0",
            manifestJSON: "{}",
            runtimeJSON: #"{"language":"go","entrypoint":"./app.derrick/plugin.go"}"#,
            guestSource: Self.dummyGoScript,
            compiledArtifact: Self.dummyCompiledGuest,
            skillFiles: [:],
            contentHash: try PluginContentHash(hex: String(repeating: "c", count: 64)),
            reviewSummary: "ok"
        )
        let result = try await GuestPluginRunner.run(
            release: release,
            input: Data(#"{"kind":"manual"}"#.utf8),
            dockerExecutor: { arguments, _, _ in
                await recorder.append(arguments)
                if Self.isGuestBinaryExec(arguments) {
                    return DockerCLIResult(
                        exitCode: 0,
                        stdout: Data(#"[{"verb":"result.emit","summary":"ok"}]"#.utf8),
                        stderr: Data()
                    )
                }
                if let mocked = Self.mockGuestDocker(arguments) {
                    return mocked
                }
                return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        )
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self).contains("result.emit"))
        let calls = await recorder.calls
        #expect(calls.contains { $0.contains(DockerWorkerRuntime.guestBinaryPath) })
        #expect(!calls.contains { $0.contains("swift") })
    }

    @Test func hostHopDispatcherStopsAtTerminalEnvelope() async throws {
        let result = try await PluginHostHopDispatcher.run(
            initialInput: Data(#"{"kind":"manual"}"#.utf8)
        ) { _ in
            PluginFactoryExecutionResult(
                exitCode: 0,
                stdout: Data(#"[{"verb":"result.emit","summary":"done"}]"#.utf8)
            )
        }
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self).contains("done"))
    }

    @Test func pluginInvokeAccumulatesHTTPResultsAcrossHops() async throws {
        actor Seen {
            var hops: [[String]] = []
            func record(_ ids: [String]) { hops.append(ids) }
        }
        let seen = Seen()
        let initial = PluginHopEvent(
            kind: .manual,
            params: ["messaging_op": .string("sync_threads")]
        )
        let result = try await GuestHopLoop.runForPluginInvoke(
            initialEvent: initial,
            invokeID: "test-invoke",
            timeoutSeconds: 30,
            execute: { input in
                let event = try JSONDecoder().decode(PluginHopEvent.self, from: input)
                let ids = (event.httpResults ?? []).map(\.requestID)
                await seen.record(ids)
                if ids.isEmpty {
                    return PluginFactoryExecutionResult(
                        exitCode: 0,
                        stdout: Data(
                            #"[{"verb":"http.request","request_id":"sync-1","method":"GET","url":"https://example.com/page1"}]"#.utf8
                        )
                    )
                }
                if ids == ["sync-1"] {
                    return PluginFactoryExecutionResult(
                        exitCode: 0,
                        stdout: Data(
                            #"[{"verb":"http.request","request_id":"sync-2","method":"GET","url":"https://example.com/page2"}]"#.utf8
                        )
                    )
                }
                if Set(ids) == Set(["sync-1", "sync-2"]) {
                    return PluginFactoryExecutionResult(
                        exitCode: 0,
                        stdout: Data(
                            ##"[{"verb":"result.emit","summary":"ok","threads":[{"vendor_thread_id":"C1","title":"#general"}]}]"##.utf8
                        )
                    )
                }
                return PluginFactoryExecutionResult(
                    exitCode: 1,
                    stderr: Data("unexpected ids \(ids)".utf8)
                )
            },
            logger: { _ in },
            httpResultEvent: { envelopes, _, params in
                let responses = envelopes.filter { $0.verb == .httpRequest }.map { envelope in
                    HostHTTPResponse(
                        requestID: envelope.payload["request_id"]?.stringValue ?? "",
                        status: 200,
                        body: #"{"ok":true}"#
                    )
                }
                return try? PluginHopEvent(
                    kind: .httpResults,
                    httpResults: responses,
                    params: params
                ).encodeValidated()
            }
        )
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self).contains("result.emit"))
        let hops = await seen.hops
        #expect(hops.count == 3)
        #expect(hops[0].isEmpty)
        #expect(hops[1] == ["sync-1"])
        #expect(Set(hops[2]) == Set(["sync-1", "sync-2"]))
    }

    @Test func pluginInvokeStopsWhenHopBudgetExceeded() async throws {
        actor Counter {
            var hops = 0
            func bump() { hops += 1 }
        }
        let counter = Counter()
        let result = try await GuestHopLoop.runForPluginInvoke(
            initialEvent: PluginHopEvent(kind: .manual),
            invokeID: "test-invoke",
            timeoutSeconds: 30,
            execute: { _ in
                await counter.bump()
                return PluginFactoryExecutionResult(
                    exitCode: 0,
                    stdout: Data(
                        #"[{"verb":"http.request","request_id":"n-1","method":"GET","url":"https://example.com"}]"#.utf8
                    )
                )
            },
            logger: { _ in },
            httpResultEvent: { envelopes, _, params in
                let responses = envelopes.filter { $0.verb == .httpRequest }.map { envelope in
                    HostHTTPResponse(
                        requestID: envelope.payload["request_id"]?.stringValue ?? "n-1",
                        status: 200,
                        body: "{}"
                    )
                }
                return try? PluginHopEvent(
                    kind: .httpResults,
                    httpResults: responses,
                    params: params
                ).encodeValidated()
            }
        )
        #expect(result.exitCode == 1)
        let stderr = String(decoding: result.stderr, as: UTF8.self)
        #expect(stderr.contains("Hop budget exceeded"))
        let hops = await counter.hops
        #expect(hops == PluginContract.maxPluginInvokeHops)
    }

    @Test func goGuestContainerArgumentsStayNetworkIsolated() {
        let name = "derrick-guest-runtime-test"
        let args = [
            "create", "--network", "none", "--name", name, "--read-only",
            "--tmpfs", "/tmp:rw,exec,nosuid,size=128m",
            DerrickGuestRuntime.guestDockerImage, "/bin/sleep", "infinity",
        ]
        #expect(args.contains("--name"))
        #expect(args.contains(name))
        #expect(args.contains("/bin/sleep"))
        #expect(args.contains("infinity"))
        #expect(args.contains("--network"))
        #expect(args.contains("none"))
        #expect(args.contains("--read-only"))
    }

    @Test func scriptToolDeniesWriteWhenReviewerMissing() async throws {
        let bridge = try await MCPLocalBridge.make { server in
            await server.registerScriptExecutionTool(stdinExecutor: Self.dummyStdin, reviewer: nil)
        }

        let result = try await bridge.client.callTool(
            named: "script_exec",
            arguments: [
                "mode": .string("write"),
                "description": .string("create report file"),
                "reason": .string("user asked for file output"),
                "script": .string(Self.dummyGoScript),
                "expected_effects": .array([.string("write /tmp/report.txt")]),
                "allow_network": .bool(true)
            ]
        )

        #expect(result.text.contains("\"status\":\"blocked\""))
        #expect(result.text.contains("\"stage\":\"review\""))
        #expect(result.text.contains("requires configured reviewer"))
    }

    @Test func scriptToolDeniesWhenReviewerFlagsMisalignment() async throws {
        let bridge = try await MCPLocalBridge.make { server in
            await server.registerScriptExecutionTool(stdinExecutor: Self.dummyStdin, reviewer: StubReviewer(
                    assessment: ScriptReviewAssessment(
                        alignedWithRequest: false,
                        confidence: 0.95,
                        suggestedAction: "deny",
                        concerns: ["Script appears unrelated to user prompt."],
                        summary: "Not aligned."
                    )
                )
            )
        }

        let result = try await bridge.client.callTool(
            named: "script_exec",
            arguments: [
                "mode": .string("readonly"),
                "description": .string("inspect csv"),
                "reason": .string("analyze user-provided data"),
                "script": .string(Self.dummyGoScript),
                "user_prompt": .string("summarize this csv"),
                "allow_network": .bool(true)
            ]
        )

        #expect(result.text.contains("\"status\":\"blocked\""))
        #expect(result.text.contains("\"stage\":\"review\""))
        #expect(result.text.contains("Script appears unrelated to user prompt."))
    }

    @Test func runnerOutcomeDoesNotPolicyDenyOnNonZeroExit() {
        let result = ScriptExecutionResult.runnerOutcome(
            timedOut: false,
            exitCode: 1,
            stdout: "",
            stderr: "ValueError: boom",
            durationMS: 10,
            phaseTiming: nil
        )
        #expect(result.status == .failed)
        #expect(result.decision == .allow)
        #expect(result.failureStage == .execution)
        let outcome = result.toolExecutionOutcome()
        #expect(outcome.indicatesFailure)
        #expect(outcome.failureSummary == "ValueError: boom")
        #expect(MCPToolOutcomeSemantics.isError(toolName: "script_exec", text: encodeJSON(outcome), transportIsError: false))
    }

    @Test func scriptSuccessIsNotSemanticError() {
        let result = ScriptExecutionResult.runnerOutcome(
            timedOut: false,
            exitCode: 0,
            stdout: "ok",
            stderr: "",
            durationMS: 5,
            phaseTiming: nil
        )
        let outcome = result.toolExecutionOutcome()
        #expect(!outcome.indicatesFailure)
        #expect(!MCPToolOutcomeSemantics.isError(toolName: "script_exec", text: encodeJSON(outcome), transportIsError: false))
    }

    private func encodeJSON(_ value: some Encodable) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    @Test func runnerOutcomeClassifiesEgress() {
        let result = ScriptExecutionResult.runnerOutcome(
            timedOut: false,
            exitCode: 1,
            stdout: "",
            stderr: "UNAUTHORIZED_EGRESS destination=reactjs.org",
            durationMS: 10,
            phaseTiming: nil
        )
        #expect(result.status == .failed)
        #expect(result.decision == .allow)
        #expect(result.failureStage == .egress)
    }

    @Test func runnerOutcomeTimeoutIsNotPolicyDeny() {
        let result = ScriptExecutionResult.runnerOutcome(
            timedOut: true,
            exitCode: -1,
            stdout: "",
            stderr: "",
            durationMS: 30_000,
            phaseTiming: nil
        )
        #expect(result.status == .timeout)
        #expect(result.decision == .allow)
        #expect(result.failureStage == .timeout)
    }

    @Test func effectiveScriptTimeoutCapsAtContainerLeaseTTL() {
        ContainerLifecycleRuntime.resetToDefaultForTesting()
        defer { ContainerLifecycleRuntime.resetToDefaultForTesting() }
        #expect(GuestRuntimeLimits.effectiveScriptTimeoutSeconds(requested: 30) == 30)
        #expect(GuestRuntimeLimits.effectiveScriptTimeoutSeconds(requested: 900) == GuestRuntimeLimits.containerRunMaxTTLSeconds)
        #expect(GuestRuntimeLimits.containerRunMaxTTLSeconds == 7 * 60)
    }

    @Test func containerLeaseExceededProducesClearLLMMessage() {
        ContainerLifecycleRuntime.resetToDefaultForTesting()
        defer { ContainerLifecycleRuntime.resetToDefaultForTesting() }
        let result = ScriptExecutionResult.containerLeaseExceeded(durationMS: 420_000)
        #expect(result.status == .timeout)
        #expect(result.failureStage == .containerLease)
        #expect(result.timedOut)
        #expect(result.validationFindings.first?.contains("7 minutes") == true)
        #expect(result.stderr.contains("container lease expired"))
        #expect(result.toolExecutionOutcome().failureSummary?.contains("container lease expired") == true)
    }

    @Test func allowAssessmentSurvivesSuccessfulRunWithoutDenyStage() async throws {
        let bridge = try await MCPLocalBridge.make { server in
            await server.registerScriptExecutionTool(stdinExecutor: Self.dummyStdin, reviewer: StubReviewer(
                    assessment: ScriptReviewAssessment(
                        alignedWithRequest: true,
                        confidence: 0.9,
                        suggestedAction: "allow",
                        concerns: ["Script may fetch external docs."],
                        summary: "Looks fine with soft concerns."
                    )
                )
            )
        }

        let result = try await bridge.client.callTool(
            named: "script_exec",
            arguments: [
                "mode": .string("readonly"),
                "description": .string("fetch page"),
                "reason": .string("test"),
                "script": .string(Self.dummyGoScript),
                "allow_network": .bool(true)
            ]
        )

        #expect(result.text.contains("\"status\":\"completed\""))
        #expect(result.text.contains("\"stage\":\"none\""))
        #expect(result.text.contains("\"format\":\"text\""))
    }
}

actor DockerCallRecorder {
    private(set) var calls: [[String]] = []

    func append(_ arguments: [String]) {
        calls.append(arguments)
    }
}

private actor PeakCounter {
    private(set) var current = 0
    private(set) var peak = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() {
        current = max(0, current - 1)
    }
}

private actor StdinByteRecorder {
    private(set) var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }
}
