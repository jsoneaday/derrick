import Foundation
import MCPServer
import Plugin
import Testing
import Structure

@Suite struct PythonPluginFactoryDockerExecutorTests {
    @Test func packagesAndRunsPythonSource() async throws {
        let recorder = DockerCallRecorder()
        let runner = PythonPluginFactoryDockerExecutor(
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
        let draft = try await runner.runGuestSource(
            source: "import json, sys\njson.dump([], sys.stdout)",
            input: Data(#"{"kind":"manual"}"#.utf8)
        )
        #expect(draft.exitCode == 0)
        let packaged = try await runner.packageGuestSource(
            source: "import json, sys\njson.dump([], sys.stdout)"
        )
        let released = try await runner.runPackagedArtifact(
            packaged,
            input: Data(#"{"kind":"manual"}"#.utf8)
        )
        #expect(released.exitCode == 0)
        let calls = await recorder.calls
        #expect(calls.contains { $0.contains("python3") && $0.contains("/tmp/guest.py") })
    }
}
