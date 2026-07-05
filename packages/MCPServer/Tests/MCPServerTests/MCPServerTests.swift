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
                status: "completed",
                decision: "allow",
                verifier: "stub",
                findings: [],
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

        #expect(result.results.map(\.content) == ["alpha", "beta"])
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

        #expect(result.content == "bridge: hello/3/2")
        #expect(result.isError == false)
    }

    @Test func pythonScriptToolIsDiscoverable() async throws {
        let bridge = try await MCPLocalBridge.make { server in
            await server.registerPythonScriptExecutionTool(runner: StubPythonRunner())
        }

        let tools = try await bridge.client.searchTools(matching: "python")
        #expect(tools.map(\.name).contains("python_script_exec"))
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
        #expect(result.content.contains("\"status\":\"blocked\""))
        #expect(result.content.contains("\"decision\":\"deny\""))
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

        #expect(result.content.contains("\"status\":\"blocked\""))
        #expect(result.content.contains("\"decision\":\"deny\""))
        #expect(result.content.contains("Write mode requires configured reviewer."))
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

        #expect(result.content.contains("\"status\":\"blocked\""))
        #expect(result.content.contains("\"decision\":\"deny\""))
        #expect(result.content.contains("Script appears unrelated to user prompt."))
    }
}
