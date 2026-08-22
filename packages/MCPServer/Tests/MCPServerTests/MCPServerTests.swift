import Foundation
import DockerRunnerXPC
import Testing
import MCPClient
import ServiceContracts
import Plugin
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

    @Test func swiftSourceVerifierRejectsHostEscapeAndDependencies() {
        let findings = SwiftScriptVerifier.validate(
            source: "import Foundation\nlet _ = URLSession.shared",
            dependencies: ["example": "1.0.0"]
        )
        #expect(findings.contains("Direct network access is not allowed; emit http.request envelopes."))
        #expect(findings.contains("Swift script dependencies are not supported; use the standard library and Foundation."))
    }

    @Test func swiftSourceVerifierAllowsStandaloneInput() {
        let findings = SwiftScriptVerifier.validate(
            source: "import Foundation\nlet data = FileHandle.standardInput.readDataToEndOfFile()"
        )
        #expect(findings.isEmpty)
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
        #expect(result.text.contains("\"failureStage\":\"staticValidation\""))
    }

    @Test func swiftExecutorUsesSwiftImage() {
        #expect(DerrickGuestRuntime.swiftPluginDockerImage.contains("swift"))
    }

    @Test func swiftRuntimeErrorUsesSwiftLanguage() {
        let error = SwiftDockerExecutorError.commandFailed("swiftc", "compile failed")
        #expect(error.localizedDescription.contains("swiftc"))
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
        #expect(result.text.contains("\"decision\":\"deny\""))
        #expect(result.text.contains("\"failureStage\":\"llmReview\""))
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
        #expect(result.text.contains("\"decision\":\"deny\""))
        #expect(result.text.contains("\"failureStage\":\"llmReview\""))
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
        #expect(result.indicatesToolError)
        #expect(result.failureSummary == "ValueError: boom")
        #expect(MCPToolOutcomeSemantics.isError(toolName: "script_exec", text: encodeJSON(result), transportIsError: false))
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
        #expect(!result.indicatesToolError)
        #expect(!MCPToolOutcomeSemantics.isError(toolName: "script_exec", text: encodeJSON(result), transportIsError: false))
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
        #expect(result.failureSummary?.contains("container lease expired") == true)
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
        #expect(result.text.contains("\"decision\":\"allow\""))
        #expect(result.text.contains("\"failureStage\":\"none\""))
        #expect(result.text.contains("Looks fine with soft concerns"))
    }
}

private actor DockerCallRecorder {
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
