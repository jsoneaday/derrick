import Testing
import MCPClient
@testable import MCPServer

@Suite struct MCPServerTests {
    private struct StubPythonRunner: PythonScriptRunner {
        func run(
            script: String,
            timeoutSeconds: Int,
            allowNetwork: Bool,
            pythonPackages: [String],
            allowDependencyInstall: Bool
        ) async throws -> PythonScriptExecutionResult {
            _ = pythonPackages
            _ = allowDependencyInstall
            return PythonScriptExecutionResult(
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
                phaseTiming: PythonScriptPhaseTiming(
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

    private struct StubReviewer: PythonScriptReviewer {
        let name: String = "stub-reviewer"
        let assessment: PythonScriptReviewAssessment

        func review(_ args: PythonScriptExecutionArguments) async throws -> PythonScriptReviewOutcome {
            _ = args
            return PythonScriptReviewOutcome(
                assessment: assessment,
                timing: PythonScriptReviewerTiming(
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

    @Test func pythonScriptToolIsDiscoverable() async throws {
        let bridge = try await MCPLocalBridge.make { server in
            await server.registerPythonScriptExecutionTool(runner: StubPythonRunner())
        }

        let tools = try await bridge.client.searchTools(matching: "python")
        #expect(tools.map(\.name).contains("python_script_exec"))
    }

    @Test func baselinePackagesIncludeLxml() {
        #expect(DockerScriptPreparer.baselinePackages.contains("requests"))
        #expect(DockerScriptPreparer.baselinePackages.contains("beautifulsoup4"))
        #expect(DockerScriptPreparer.baselinePackages.contains("chardet"))
        #expect(DockerScriptPreparer.baselinePackages.contains("lxml"))
    }

    @Test func executionScriptVerifiesBaselinePackagesBeforeRunningUserCode() {
        let script = DockerScriptPreparer.makeExecutionScript(
            script: "print('hello')",
            installPackages: [],
            allowDependencyInstall: false,
            nonBaselinePackages: []
        )

        #expect(script.contains("verified baseline package"))
        #expect(script.contains("baseline package verification failed"))
        #expect(script.contains("lxml"))
        #expect(script.contains("sys.path.insert(0, \"/packages\")"))
        #expect(!script.contains("installing packages: requests"))
        #expect(script.contains("_wipe_ephemeral_dir(\"/tmp\")"))
        #expect(script.contains("_wipe_ephemeral_dir(\"/var/tmp\")"))
        #expect(script.contains("wiped /tmp and /var/tmp"))
    }

    @Test func verifierBlocksNonPackageWritesUnderPackagesVolume() {
        let args = PythonScriptExecutionArguments(
            mode: .write,
            description: "save report",
            reason: "user asked for a file",
            script: "open('/packages/report.json', 'w').write('{}')",
            userPrompt: "save a report",
            expectedEffects: ["write report"],
            pythonPackages: [],
            allowDependencyInstall: false,
            timeoutSeconds: 30,
            allowNetwork: false
        )
        let findings = PythonScriptExecutionVerifier.validate(args)
        #expect(findings.contains(where: { $0.contains("/packages") }))
    }

    @Test func verifierAllowsScriptsThatDoNotWritePackagesVolume() {
        let args = PythonScriptExecutionArguments(
            mode: .readonly,
            description: "fetch data",
            reason: "user asked for info",
            script: "import requests\nprint(requests.get('https://example.com').status_code)",
            userPrompt: "check example.com",
            expectedEffects: [],
            pythonPackages: [],
            allowDependencyInstall: false,
            timeoutSeconds: 30,
            allowNetwork: true
        )
        let findings = PythonScriptExecutionVerifier.validate(args)
        #expect(!findings.contains(where: { $0.contains("/packages") }))
    }

    @Test func extraPackagesExcludesBaseline() {
        let extras = DockerScriptPreparer.extraPackages(from: ["requests", "pandas", "lxml", "numpy"])
        #expect(extras == ["pandas", "numpy"] || extras == ["numpy", "pandas"])
        #expect(Set(extras) == Set(["pandas", "numpy"]))
    }

    @Test func phaseTimingScriptMetricsCountLinesAndChars() {
        let script = "import json\nprint(1)\n"
        let metrics = PythonScriptPhaseTiming.scriptMetrics(script)
        #expect(metrics.chars == script.utf8.count)
        #expect(metrics.lines == 3)
        var phase = PythonScriptPhaseTiming(
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
            PythonScriptReviewerTiming(
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
        #expect(summary.contains("reviewer_ms=10"))
        #expect(summary.contains("exec_ms=3"))
        #expect(summary.contains("reviewer_ttfb_ms=4"))
        #expect(summary.contains("reviewer_stream_ms=5"))
        #expect(summary.contains("reviewer_response_chars=200"))
        #expect(summary.contains("reviewer_model=gpt-5.6-luna"))
    }

    @Test func dockerExecUsesWarmContainer() {
        let args = DockerScriptPreparer.dockerExecArguments(allowNetwork: true)
        #expect(args.contains("exec"))
        #expect(args.contains(DockerScriptPreparer.warmContainerNetwork))
        #expect(args.contains(DockerScriptPreparer.baselinePythonPath))
    }

    @Test func warmContainerCreateMountsPackagesVolume() {
        let offline = DockerScriptPreparer.dockerCreateWarmContainerArguments(allowNetwork: false)
        #expect(offline.contains(DockerScriptPreparer.packagesVolume + ":/packages") ||
                offline.contains { $0.contains(DockerScriptPreparer.packagesVolume) })
        #expect(offline.contains(DockerScriptPreparer.warmContainerNoNetwork))
        #expect(offline.contains("--entrypoint"))
        #expect(offline.contains(DockerScriptPreparer.offlineHoldBinary))
        #expect(offline.contains(DockerScriptPreparer.offlineHoldArg))
        #expect(offline.contains("--network"))
        #expect(offline.contains("none"))

        let online = DockerScriptPreparer.dockerCreateWarmContainerArguments(allowNetwork: true)
        #expect(online.contains(DockerScriptPreparer.forcedEgressHoldPath))
        #expect(online.contains("NET_ADMIN"))
        #expect(online.contains { $0.contains("HTTPS_PROXY=") })
        #expect(online.contains(DockerScriptPreparer.warmContainerNetwork))
        // Image must be last so Docker does not treat an -e value as the image ref.
        #expect(online.last == DockerScriptPreparer.defaultImage)
        if let imageIndex = online.lastIndex(of: DockerScriptPreparer.defaultImage) {
            #expect(online[..<imageIndex].allSatisfy { !$0.hasPrefix("derrick-python:") || $0 == DockerScriptPreparer.defaultImage })
            #expect(!online[..<imageIndex].contains { $0.contains("://") && !$0.hasPrefix("-") && !$0.contains("=") })
        }
    }

    @Test func baselineDockerfileIncludesForcedEgressHold() {
        let dockerfile = DockerScriptPreparer.baselineDockerfile
        #expect(dockerfile.contains("iptables"))
        #expect(dockerfile.contains(DockerScriptPreparer.forcedEgressHoldPath))
        #expect(dockerfile.contains("base64 -d"))
        #expect(DockerScriptPreparer.forcedEgressHoldScript.contains("OUTPUT DROP"))
        #expect(DockerScriptPreparer.forcedEgressHoldScript.contains("exec /bin/sleep infinity"))
        #expect(!DockerScriptPreparer.forcedEgressHoldScript.contains("awk \"{print"))
    }

    @Test func baselineDockerfileInstallsBaselinePackages() {
        let dockerfile = DockerScriptPreparer.baselineDockerfile
        #expect(dockerfile.contains(DockerScriptPreparer.parentImage))
        #expect(dockerfile.contains("uv venv"))
        #expect(dockerfile.contains("uv pip install"))
        #expect(dockerfile.contains("--system") == false)
        #expect(dockerfile.contains(DockerScriptPreparer.baselineVenvPath))
        #expect(dockerfile.contains("requests"))
        #expect(dockerfile.contains("lxml"))
    }

    @Test func dockerExecUsesBaselineVenvPython() {
        let args = DockerScriptPreparer.dockerExecArguments(allowNetwork: false)
        #expect(args.contains(DockerScriptPreparer.baselinePythonPath))
        #expect(!args.contains("python3"))
    }

    @Test func dockerUnavailableMessageIgnoresPackageLoadFailures() {
        let stderr = "[python_script_exec] baseline package verification failed: charset_normalizer -> charset_normalizer: Error loading shared library /packages/charset_normalizer/cd.cpython-312-aarch64-linux-musl.so: Operation not permitted"

        #expect(DockerScriptPreparer.dockerUnavailableMessage(stderr: stderr, exitCode: 1) == nil)
        #expect(DockerScriptPreparer.dockerUnavailableMessage(stderr: stderr, exitCode: 127) != nil)
    }

    @Test func pythonScriptToolBlocksReadonlyViolations() async throws {
        let bridge = try await MCPLocalBridge.make { server in
            await server.registerPythonScriptExecutionTool(
                runner: StubPythonRunner(),
                reviewer: StubReviewer(
                    assessment: PythonScriptReviewAssessment(
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
            named: "python_script_exec",
            arguments: [
                "mode": .string("readonly"),
                "description": .string("attempt write"),
                "reason": .string("test"),
                "script": .string("open('/tmp/a', 'w').write('x')")
            ]
        )

        #expect(result.isError == false)
        #expect(result.text.contains("\"status\":\"blocked\""))
        #expect(result.text.contains("\"decision\":\"deny\""))
        #expect(result.text.contains("\"failureStage\":\"staticValidation\""))
    }

    @Test func pythonScriptToolDeniesWriteWhenReviewerMissing() async throws {
        let bridge = try await MCPLocalBridge.make { server in
            await server.registerPythonScriptExecutionTool(runner: StubPythonRunner(), reviewer: nil)
        }

        let result = try await bridge.client.callTool(
            named: "python_script_exec",
            arguments: [
                "mode": .string("write"),
                "description": .string("create report file"),
                "reason": .string("user asked for file output"),
                "script": .string("print('hello')"),
                "expected_effects": .array([.string("write /tmp/report.txt")]),
                "allow_network": .bool(true)
            ]
        )

        #expect(result.text.contains("\"status\":\"blocked\""))
        #expect(result.text.contains("\"decision\":\"deny\""))
        #expect(result.text.contains("\"failureStage\":\"llmReview\""))
        #expect(result.text.contains("requires configured reviewer"))
    }

    @Test func pythonScriptToolDeniesWhenReviewerFlagsMisalignment() async throws {
        let bridge = try await MCPLocalBridge.make { server in
            await server.registerPythonScriptExecutionTool(
                runner: StubPythonRunner(),
                reviewer: StubReviewer(
                    assessment: PythonScriptReviewAssessment(
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
            named: "python_script_exec",
            arguments: [
                "mode": .string("readonly"),
                "description": .string("inspect csv"),
                "reason": .string("analyze user-provided data"),
                "script": .string("print('hi')"),
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
        let result = PythonScriptExecutionResult.runnerOutcome(
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
    }

    @Test func runnerOutcomeClassifiesEgress() {
        let result = PythonScriptExecutionResult.runnerOutcome(
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
        let result = PythonScriptExecutionResult.runnerOutcome(
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

    @Test func allowAssessmentSurvivesSuccessfulRunWithoutDenyStage() async throws {
        let bridge = try await MCPLocalBridge.make { server in
            await server.registerPythonScriptExecutionTool(
                runner: StubPythonRunner(),
                reviewer: StubReviewer(
                    assessment: PythonScriptReviewAssessment(
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
            named: "python_script_exec",
            arguments: [
                "mode": .string("readonly"),
                "description": .string("fetch page"),
                "reason": .string("test"),
                "script": .string("print('hi')"),
                "allow_network": .bool(true)
            ]
        )

        #expect(result.text.contains("\"status\":\"completed\""))
        #expect(result.text.contains("\"decision\":\"allow\""))
        #expect(result.text.contains("\"failureStage\":\"none\""))
        #expect(result.text.contains("Looks fine with soft concerns"))
    }
}
