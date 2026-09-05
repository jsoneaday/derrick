import Foundation
import DockerRunnerXPC
import Testing
import MCPClient
import Structure
import Plugin
import WebCrawler
@testable import MCPServer

@Suite struct MCPServerTests {
    private static let dummyStdin: @Sendable ([String], Data, Int) async throws -> DockerCLIResult = { arguments, _, _ in
        if arguments.contains("base64") {
            let artifact = Data("compiled".utf8).base64EncodedString()
            return DockerCLIResult(exitCode: 0, stdout: Data(artifact.utf8), stderr: Data())
        }
        if arguments.contains("/tmp/plugin"),
           !arguments.contains("chmod"),
           !arguments.contains("cat") {
            return DockerCLIResult(
                exitCode: 0,
                stdout: Data(#"[{"verb":"result.emit","summary":"ok"}]"#.utf8),
                stderr: Data()
            )
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

    @Test func dockerProductImagePrewarmerSkipsBuildWhenImagePresent() async throws {
        let recorder = DockerCallRecorder()
        let executor: DockerCLIExecutor = { args, _, _ in
            await recorder.append(args)
            return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        try await DockerProductImagePrewarmer.ensureWebCrawlerImage(executor: executor)
        #expect(await recorder.calls == [["image", "inspect", DockerProductImagePolicy.webCrawlerImage]])
    }

    @Test func dockerProductImagePrewarmerBuildsWhenImageMissing() async throws {
        guard DerrickRepositoryRoot.locate() != nil else { return }
        let recorder = DockerCallRecorder()
        let executor: DockerCLIExecutor = { args, _, _ in
            await recorder.append(args)
            if args.first == "image" {
                return DockerCLIResult(exitCode: 1, stdout: Data(), stderr: Data())
            }
            if args.first == "build" {
                return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        try await DockerProductImagePrewarmer.ensureWebCrawlerImage(executor: executor)
        let calls = await recorder.calls
        #expect(calls.count == 2)
        #expect(calls[0] == ["image", "inspect", DockerProductImagePolicy.webCrawlerImage])
        #expect(calls[1].first == "build")
        #expect(calls[1].contains(DockerProductImagePolicy.webCrawlerImage))
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
                        stderr: Data("swift runtime failed".utf8)
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
        #expect(result.text.contains("swift runtime failed"))
    }

    @Test func pluginFactorySurfacesReviewFailureOutcome() async throws {
        let bridge = try await MCPLocalBridge.make { server in
            await server.register(
                PluginFactoryToolModule.makeRegistration { _ in
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
        let script = "import Foundation\nprint(1)\n"
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
            method: "GET",
            urlString: "https://example.com/",
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

    @Test func pythonGuestRuntimeUsesPinnedImage() {
        #expect(DerrickGuestRuntime.pythonGuestDockerImage == "python:3.14.7")
        #expect(PythonGuestDockerExecutor.containerPrefix == "derrick-guest-runtime")
    }

    @Test func pythonSourceVerifierRejectsNetworkAndDependencies() {
        let findings = PythonScriptVerifier.validate(
            source: "import sys\nimport requests",
            dependencies: ["example": "1.0.0"]
        )
        #expect(findings.contains("Direct network access is not allowed; emit http.request envelopes."))
        #expect(findings.contains("Guest plugin dependencies are not supported; use the standard library."))
    }

    @Test func pythonSourceVerifierRequiresStdin() {
        let findings = PythonScriptVerifier.validate(source: "print('[]')")
        #expect(findings.contains("Python source must read its JSON event from standard input."))
    }

    @Test func pythonExecutorUsesReadOnlyOfflineContainer() async throws {
        let recorder = DockerCallRecorder()
        let runner = PythonGuestDockerExecutor(
            image: "python:3.14.7",
            executor: { arguments, _, _ in
                await recorder.append(arguments)
                if arguments.contains("/tmp/guest.py"),
                   !arguments.contains("cat") {
                    return DockerCLIResult(
                        exitCode: 0,
                        stdout: Data(#"[{"verb":"result.emit","summary":"ok"}]"#.utf8),
                        stderr: Data()
                    )
                }
                return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        )
        _ = try await runner.runSource(
            source: "import json, sys\njson.dump([], sys.stdout)",
            input: Data(#"{"kind":"script"}"#.utf8)
        )

        let calls = await recorder.calls
        let create = calls.first(where: { $0.first == "create" }) ?? []
        #expect(create.contains("--network"))
        #expect(create.contains("none"))
        #expect(create.contains("--read-only"))
        let exec = calls.first(where: { $0.contains("python3") }) ?? []
        #expect(exec.contains("/tmp/guest.py"))
    }

    @Test func pythonGuestDockerCommandsPassXPCValidation() async throws {
        let recorder = DockerCallRecorder()
        let runner = PythonGuestDockerExecutor(
            image: "python:3.14.7",
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
                if arguments.contains("/tmp/guest.py"),
                   !arguments.contains("cat") {
                    return DockerCLIResult(
                        exitCode: 0,
                        stdout: Data(#"[{"verb":"result.emit","summary":"ok"}]"#.utf8),
                        stderr: Data()
                    )
                }
                return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        )
        let result = try await runner.runSource(
            source: "import json, sys\njson.dump([], sys.stdout)",
            input: Data(#"{"kind":"script"}"#.utf8)
        )
        #expect(result.exitCode == 0)
        let calls = await recorder.calls
        #expect(calls.contains { $0.contains("sh") && $0.contains("cat > /tmp/guest.py") })
        #expect(calls.contains { $0.contains("python3") && $0.contains("/tmp/guest.py") })
    }

    @Test func swiftRuntimeUsesPinnedImage() {
        #expect(SwiftScriptPreparer.image == DerrickGuestRuntime.swiftPluginDockerImage)
        #expect(SwiftScriptPreparer.containerPrefix == "derrick-swift-runtime")
        #expect(SwiftScriptPreparer.maxTimeoutSeconds == 300)
    }

    @Test func swiftExecutorUsesReadOnlyExecutableContainer() async throws {
        let recorder = DockerCallRecorder()
        let runner = SwiftDockerExecutor(
            image: "swift:pinned",
            executor: { arguments, _, _ in
                await recorder.append(arguments)
                if arguments.contains("base64") {
                    let artifact = Data("compiled".utf8).base64EncodedString()
                    return DockerCLIResult(exitCode: 0, stdout: Data(artifact.utf8), stderr: Data())
                }
                if arguments.contains("/tmp/plugin"),
                   !arguments.contains("chmod"),
                   !arguments.contains("cat") {
                    return DockerCLIResult(
                        exitCode: 0,
                        stdout: Data(#"[{"verb":"result.emit","summary":"ok"}]"#.utf8),
                        stderr: Data()
                    )
                }
                return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        )
        let artifact = try await runner.compile(source: "import Foundation\nprint(\"[]\")")
        _ = try await runner.runArtifact(artifact, input: Data(#"{"kind":"manual"}"#.utf8))

        let calls = await recorder.calls
        let create = calls.first(where: { $0.first == "create" }) ?? []
        #expect(create.contains("--network"))
        #expect(create.contains("none"))
        #expect(create.contains("--read-only"))
        #expect(create.contains("--tmpfs"))
        #expect(create.contains { $0.contains("exec") })
    }

    @Test func guestSourceVerifierRejectsHostEscapeAndDependencies() {
        let findings = SwiftScriptVerifier.validate(
            source: "import Foundation\nlet _ = URLSession.shared",
            dependencies: ["example": "1.0.0"]
        )
        #expect(findings.contains("Direct network access is not allowed; emit http.request envelopes."))
        #expect(findings.contains("Swift script dependencies are not supported; use the standard library and Foundation."))
    }

    @Test func guestSourceVerifierAllowsStandaloneInput() {
        let findings = SwiftScriptVerifier.validate(
            source: "import Foundation\nlet data = FileHandle.standardInput.readDataToEndOfFile()"
        )
        #expect(findings.isEmpty)
    }

    @Test func swiftScriptCanReturnHTMLResult() async throws {
        let resultText = try await ScriptExecutionRuntime.run(
            arguments: [
                "description": .string("render a safe card"),
                "reason": .string("manual HTML output check"),
                "script": .string(
                    "import Foundation\nlet _ = FileHandle.standardInput.readDataToEndOfFile()\nprint(\"[]\")"
                )
            ],
            stdinExecutor: { arguments, _, _ in
                if arguments.contains("base64") {
                    return DockerCLIResult(
                        exitCode: 0,
                        stdout: Data(Data("compiled".utf8).base64EncodedString().utf8),
                        stderr: Data()
                    )
                }
                if arguments.contains("/tmp/plugin"),
                   !arguments.contains("chmod"),
                   !arguments.contains("cat") {
                    return DockerCLIResult(
                        exitCode: 0,
                        stdout: Data(
                            #"[{"verb":"result.emit","html":"<p><strong>Safe</strong></p>"}]"#.utf8
                        ),
                        stderr: Data()
                    )
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

    @Test func swiftScriptToolBlocksReadonlyViolations() async throws {
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
                "script": .string(
                    "import Foundation\nlet _ = FileManager.default.createDirectory(atPath: \"/tmp/a\", withIntermediateDirectories: true)"
                )
            ]
        )

        #expect(result.text.contains("\"status\":\"blocked\""))
        #expect(result.text.contains("\"stage\":\"validation\""))
    }

    @Test func swiftExecutorUsesSwiftImage() {
        #expect(DerrickGuestRuntime.swiftPluginDockerImage.contains("swift"))
    }

    @Test func swiftRuntimeErrorUsesSwiftLanguage() {
        let error = SwiftDockerExecutorError.commandFailed("swiftc", "compile failed")
        #expect(error.localizedDescription.contains("swiftc"))
    }

    @Test func guestPluginRunnerRunsPythonRelease() async throws {
        let recorder = DockerCallRecorder()
        let release = PluginFactoryRelease(
            pluginID: "slack-connection",
            version: "1.0.0",
            manifestJSON: "{}",
            runtimeJSON: #"{"language":"python","entrypoint":"./app.derrick/plugin.py"}"#,
            guestSource: "import json, sys\njson.dump([{\"verb\":\"result.emit\",\"summary\":\"ok\"}], sys.stdout)",
            compiledArtifact: Data(),
            skillFiles: [:],
            contentHash: try PluginContentHash(hex: String(repeating: "c", count: 64)),
            reviewSummary: "ok"
        )
        let result = try await GuestPluginRunner.run(
            release: release,
            input: Data(#"{"kind":"manual"}"#.utf8),
            dockerExecutor: { arguments, _, _ in
                await recorder.append(arguments)
                if arguments.contains("/tmp/guest.py"),
                   !arguments.contains("cat") {
                    return DockerCLIResult(
                        exitCode: 0,
                        stdout: Data(#"[{"verb":"result.emit","summary":"ok"}]"#.utf8),
                        stderr: Data()
                    )
                }
                return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        )
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self).contains("result.emit"))
        let calls = await recorder.calls
        #expect(calls.contains { $0.contains("python3") })
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

    @Test func swiftContainerArgumentsStayNetworkIsolated() {
        let name = "derrick-swift-runtime-test"
        let args = [
            "create", "--network", "none", "--name", name, "--read-only",
            "--tmpfs", "/tmp:rw,exec,nosuid,size=128m",
            "swiftlang/swift:nightly-6.4.x-noble", "/bin/sleep", "infinity",
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
                "script": .string("import Foundation\nlet _ = FileHandle.standardInput.readDataToEndOfFile()\nprint(\"[]\")"),
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
                "script": .string("import Foundation\nlet _ = FileHandle.standardInput.readDataToEndOfFile()\nprint(\"[]\")"),
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
        #expect(SwiftScriptPreparer.effectiveScriptTimeoutSeconds(requested: 30) == 30)
        #expect(SwiftScriptPreparer.effectiveScriptTimeoutSeconds(requested: 900) == SwiftScriptPreparer.containerRunMaxTTLSeconds)
        #expect(SwiftScriptPreparer.containerRunMaxTTLSeconds == 7 * 60)
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
                "script": .string("import Foundation\nlet _ = FileHandle.standardInput.readDataToEndOfFile()\nprint(\"[]\")"),
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

private actor StdinByteRecorder {
    private(set) var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }
}
