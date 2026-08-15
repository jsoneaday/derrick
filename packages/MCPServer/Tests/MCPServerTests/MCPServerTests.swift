import Foundation
import Testing
import MCPClient
import ServiceContracts
import Plugin
@testable import MCPServer

@Suite struct MCPServerTests {
    private struct StubScriptRunner: ScriptRunner {
        func run(
            script: String,
            timeoutSeconds: Int,
            allowNetwork: Bool,
            packages: [String],
            allowDependencyInstall: Bool
        ) async throws -> ScriptExecutionResult {
            _ = packages
            _ = allowDependencyInstall
            return ScriptExecutionResult(
                status: .completed,
                decision: .allow,
                failureStage: .none,
                verifier: "stub",
                validationFindings: [],
                reviewerAssessment: nil,
                stdout: "ok:\(script.count)",
                stderr: "",
                exitCode: 0,
                timedOut: false,
                durationMS: 1,
                phaseTiming: ScriptPhaseTiming(
                    ensureMS: 1,
                    execMS: 1,
                    totalMS: 1,
                    scriptCharCount: script.utf8.count,
                    scriptLineCount: 1,
                    wrapperCharCount: 0
                )
            )
        }
    }

    private static let dummyStdin: @Sendable ([String], Data, Int) async throws -> DockerCLIResult = { _, _, _ in
        DockerCLIResult(exitCode: 0, stdout: Data("[]".utf8), stderr: Data())
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

    @Test func bunBaselineDockerfileHasNoPythonToolchain() {
        let dockerfile = DockerScriptPreparer.baselineDockerfile
        #expect(dockerfile.contains(DockerScriptPreparer.parentImage))
        #expect(dockerfile.contains("oven/bun:1-debian"))
        #expect(!dockerfile.contains("uv venv"))
        #expect(!dockerfile.contains("uv pip install"))
        #expect(!dockerfile.contains("playwright"))
        #expect(!dockerfile.contains("crawlee"))
        #expect(dockerfile.contains("runner.js") || dockerfile.contains("base64 -d"))
    }

    @Test func phaseTimingScriptMetricsCountLinesAndChars() {
        let script = "import json\nprint(1)\n"
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

    @Test func httpNilErrorIsSuccessOnTheWire() throws {
        let ok = HostHTTPFetch(status: 200, headers: [:], body: "<html>", error: nil)
        #expect(ok.succeeded)
        let response = ok.response(requestID: "r1")
        #expect(response.succeeded)
        #expect(response.error == nil)
        let invoke = PluginHostInvoke(seq: 1, event: PluginHopEvent(kind: .httpResults, httpResults: [response]))
        let data = try JSONWire.encode(invoke)
        let decoded = try JSONDecoder().decode(PluginHostInvoke.self, from: data)
        #expect(decoded.event.httpResults?.first?.succeeded == true)
        #expect(decoded.event.httpResults?.first?.error == nil)
        #expect(decoded.event.httpResults?.first?.body == "<html>")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let results = (object?["event"] as? [String: Any])?["http_results"] as? [[String: Any]]
        #expect(results?.first?["body"] as? String == "<html>")
        #expect(results?.first?["json"] == nil)
    }

    @Test func dockerfileInstallsTypeScriptAndGuestIsTS() {
        let dockerfile = DockerScriptPreparer.baselineDockerfile
        #expect(dockerfile.contains("bun add -g typescript@7"))
        #expect(dockerfile.contains("tsc --version"))
        #expect(DerrickGuestRuntime.dockerImage == "derrick-bun:baseline-3")
        #expect(!DerrickGuestTypeScript.tsconfigJSON.contains("baseUrl"))
        #expect(!DerrickGuestTypeScript.handleCheckTS.contains("./script.ts"))
        #expect(DockerScriptPreparer.guestRunnerJS.contains("script.ts"))
        #expect(DerrickGuestTypeScript.handleCheckTS.contains("HandleResult"))
    }

    @Test func injectHelpersForwardsNonEmptyStdinAndRejectsEmptyWrite() async throws {
        var stdinBytes: [Int] = []
        try await DockerVolumeIO.injectHelpers { args, stdin, _ in
            if args.contains("exec") {
                stdinBytes.append(stdin.count)
                return DockerCLIResult(
                    exitCode: 0,
                    stdout: Data("\(stdin.count)".utf8),
                    stderr: Data()
                )
            }
            return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        #expect(stdinBytes.count == 4)
        #expect(stdinBytes.allSatisfy { $0 > 0 })

        await #expect(throws: VolumeIOPathError.self) {
            try await DockerVolumeIO.writeFile(
                volume: DerrickNamedVolume.helpers,
                relativePath: "empty.txt",
                data: Data(),
                exec: { _, _, _ in DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data()) }
            )
        }
    }

    @Test func typecheckFailureIsShownToUser() {
        let err = ScriptLeaseError.typecheckFailed("script.ts(1,1): error TS2322: Type 'string' is not assignable to type 'HandleResult'.")
        #expect(err.errorDescription?.contains("TS2322") == true)
        #expect(err.errorDescription?.contains("TypeScript check failed") == true)
    }

    @Test func bunPoolCreateUsesSleepHoldAndBunImage() {
        let name = DockerScriptPreparer.poolContainerName(slotIndex: 0)
        #expect(name == "derrick-runner-bun-1-0")
        let args = DockerScriptPreparer.dockerCreateWarmContainerArguments(containerName: name)
        #expect(args.contains("--name"))
        #expect(args.contains(name))
        #expect(args.contains("/bin/sleep"))
        #expect(args.contains("infinity"))
        #expect(args.contains(DerrickGuestRuntime.dockerImage))
        #expect(args.contains("-v"))
        #expect(args.contains { $0.hasPrefix("derrick-script-scratch-") })
        #expect(args.contains { $0.contains("derrick-script-helpers") })
        #expect(!args.contains("NET_ADMIN"))
        #expect(!args.contains { $0.contains("PLAYWRIGHT") })
        #expect(!args.contains("HTTP_PROXY"))
        #expect(!args.contains { $0.contains("host.docker.internal") })
    }

    @Test func handoffCreateIsNetworkNoneReadOnly() {
        let args = DockerScriptPreparer.dockerCreateHandoffArguments(
            containerName: "derrick-runner-bun-1-0",
            scratchVolume: "derrick-script-scratch-slot-0"
        )
        #expect(args.contains("--network"))
        #expect(args.contains("none"))
        #expect(args.contains("--read-only"))
        #expect(!args.contains("HTTP_PROXY"))
        #expect(DockerScriptPreparer.poolSlotCount == 2)
    }

    @Test func volumeIORejectsEscapingPath() throws {
        #expect(throws: VolumeIOPathError.self) {
            _ = try DockerVolumeIO.validatedRelativePath("../etc/passwd")
        }
        let ok = try DockerVolumeIO.validatedRelativePath("runner.js")
        #expect(ok == "runner.js")
    }

    @Test func bunPoolExecUsesRunner() {
        let name = DockerScriptPreparer.poolContainerName(slotIndex: 0)
        let args = DockerScriptPreparer.dockerExecArguments(containerName: name)
        #expect(args.contains("exec"))
        #expect(args.contains(name))
        #expect(args.contains("bun"))
        #expect(args.contains(DockerScriptPreparer.runnerPath))
    }

    @Test func dockerUnavailableMessageIgnoresPackageLoadFailures() {
        let stderr = "[script_exec] baseline package verification failed: charset_normalizer -> charset_normalizer: Error loading shared library /workspace/node_modules/charset_normalizer/cd.node: Operation not permitted"

        #expect(DockerScriptPreparer.dockerUnavailableMessage(stderr: stderr, exitCode: 1) == nil)
        #expect(DockerScriptPreparer.dockerUnavailableMessage(stderr: stderr, exitCode: 127) != nil)
    }

    @Test func scriptToolBlocksReadonlyViolations() async throws {
        let bridge = try await MCPLocalBridge.make { server in
            await server.registerScriptExecutionTool(stdinExecutor: Self.dummyStdin, reviewer: StubReviewer(
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
                "mode": .string("readonly"),
                "description": .string("attempt write"),
                "reason": .string("test"),
                "script": .string("export function handle() { writeFile('/tmp/a', 'x'); return []; }")
            ]
        )

        #expect(result.isError == false)
        #expect(result.text.contains("\"status\":\"blocked\""))
        #expect(result.text.contains("\"decision\":\"deny\""))
        #expect(result.text.contains("\"failureStage\":\"staticValidation\""))
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
                "script": .string("export function handle() { return [{ verb: 'result.emit', summary: 'hello' }]; }"),
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
                "script": .string("export function handle() { return [{ verb: 'result.emit', summary: 'hi' }]; }"),
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
        #expect(DockerScriptPreparer.effectiveScriptTimeoutSeconds(requested: 30) == 30)
        #expect(DockerScriptPreparer.effectiveScriptTimeoutSeconds(requested: 900) == DockerScriptPreparer.containerRunMaxTTLSeconds)
        #expect(DockerScriptPreparer.containerRunMaxTTLSeconds == 7 * 60)
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
                "script": .string("export function handle() { return [{ verb: 'result.emit', summary: 'hi' }]; }"),
                "allow_network": .bool(true)
            ]
        )

        #expect(result.text.contains("\"status\":\"completed\""))
        #expect(result.text.contains("\"decision\":\"allow\""))
        #expect(result.text.contains("\"failureStage\":\"none\""))
        #expect(result.text.contains("Looks fine with soft concerns"))
    }
}
