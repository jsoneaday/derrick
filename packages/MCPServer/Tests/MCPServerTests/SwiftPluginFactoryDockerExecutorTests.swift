import DockerRunnerXPC
import Foundation
import Plugin
import Testing
@testable import MCPServer

@Suite struct SwiftPluginFactoryDockerExecutorTests {
    @Test func adapterRunsCompilesAndRunsTheVerifiedArtifactInDocker() async throws {
        let recorder = DockerCallRecorder()
        let artifact = Data("compiled".utf8)
        let runner = SwiftPluginFactoryDockerExecutor(
            image: "swift:pinned",
            executor: { arguments, stdin, _ in
                await recorder.append(arguments: arguments, stdin: stdin)
                if arguments.contains("base64") {
                    return DockerCLIResult(
                        exitCode: 0,
                        stdout: Data(artifact.base64EncodedString().utf8),
                        stderr: Data()
                    )
                }
                if arguments.contains("swift") || arguments.contains("/tmp/plugin") {
                    return DockerCLIResult(
                        exitCode: 0,
                        stdout: Data(#"[{"verb":"result.emit","summary":"ok"}]"#.utf8),
                        stderr: Data()
                    )
                }
                return DockerCLIResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        )

        let draft = try await runner.runSwiftFile(
            source: "import Foundation\nprint(\"[]\")",
            input: Data(#"{"kind":"manual"}"#.utf8)
        )
        #expect(draft.exitCode == 0)

        let compiled = try await runner.compileSwiftFile(source: "import Foundation\nprint(\"[]\")")
        #expect(compiled == artifact)

        let released = try await runner.runCompiledArtifact(
            artifact,
            input: Data(#"{"kind":"manual"}"#.utf8)
        )
        #expect(released.exitCode == 0)
        #expect(try PluginEnvelopeList.decode(released.stdout).count == 1)

        let calls = await recorder.calls
        #expect(calls.contains { $0.first == "create" && $0.contains("swift:pinned") })
        #expect(calls.contains { $0.first == "start" })
        #expect(calls.contains { $0.contains("swift") && $0.contains("/tmp/plugin.swift") })
        #expect(calls.contains { $0.contains("swiftc") && $0.contains("-O") })
        #expect(calls.filter { $0.first == "rm" }.count == 3)
    }
}

private actor DockerCallRecorder {
    private(set) var calls: [[String]] = []

    func append(arguments: [String], stdin: Data) {
        _ = stdin
        calls.append(arguments)
    }
}
