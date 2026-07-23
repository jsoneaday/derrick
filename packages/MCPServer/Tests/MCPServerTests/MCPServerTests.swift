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
                verifier: "stub",
                validationFindings: [],
                reviewerAssessment: nil,
                stdout: "ok:\(script.count)",
                stderr: "",
                exitCode: 0,
                timedOut: false,
                durationMS: 1
            )
        }
    }

    private struct StubReviewer: PythonScriptReviewer {
        let name: String = "stub-reviewer"
        let assessment: PythonScriptReviewAssessment

        func review(_ args: PythonScriptExecutionArguments) async throws -> PythonScriptReviewAssessment {
            _ = args
            return assessment
        }
    }

    @Test func registrySearchMatchesToolName() async throws {
        let registry = MCPToolRegistry()
        await registry.register(name: "tool_search", description: "Search tools") { _ in "ok" }

        let results = await registry.search(matching: "search")

        #expect(results.map(\.name) == ["tool_search"])
    }

    @Test func batchCallAggregatesResults() async throws {
        let registry = MCPToolRegistry()
        await registry.register(name: "tool_one", description: "First tool") { _ in "alpha" }
        await registry.register(name: "tool_two", description: "Second tool") { _ in "beta" }

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

    @Test func dockerExecUsesWarmContainer() {
        let args = DockerScriptPreparer.dockerExecArguments(allowNetwork: true)
        #expect(args.contains("exec"))
        #expect(args.contains(DockerScriptPreparer.warmContainerNetwork))
        #expect(args.contains(DockerScriptPreparer.baselinePythonPath))
    }

    @Test func warmContainerCreateMountsPackagesVolume() {
        let args = DockerScriptPreparer.dockerCreateWarmContainerArguments(allowNetwork: false)
        #expect(args.contains(DockerScriptPreparer.packagesVolume + ":/packages") ||
                args.contains { $0.contains(DockerScriptPreparer.packagesVolume) })
        #expect(args.contains(DockerScriptPreparer.warmContainerNoNetwork))
        #expect(args.contains("--entrypoint"))
        #expect(args.contains(DockerScriptPreparer.warmContainerHoldBinary))
        #expect(args.contains(DockerScriptPreparer.warmContainerHoldArg))
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
                "expected_effects": .array([.string("write /tmp/report.txt")])
            ]
        )

        #expect(result.text.contains("\"status\":\"blocked\""))
        #expect(result.text.contains("\"decision\":\"deny\""))
        #expect(result.text.contains("Write mode requires configured reviewer."))
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
                "user_prompt": .string("summarize this csv")
            ]
        )

        #expect(result.text.contains("\"status\":\"blocked\""))
        #expect(result.text.contains("\"decision\":\"deny\""))
        #expect(result.text.contains("Script appears unrelated to user prompt."))
    }
}
