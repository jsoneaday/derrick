import Foundation
import Testing
@testable import DockerRunnerXPC

struct DockerRunnerXPCTests {
    @Test func requestRoundTripsThroughJSON() throws {
        let request = DockerRunRequest(
            executablePath: "/usr/bin/env",
            arguments: ["docker", "run", "--rm", "image"],
            environment: ["PATH": "/usr/bin"],
            stdinData: Data("print(1)".utf8),
            timeoutSeconds: 30
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(DockerRunRequest.self, from: data)
        #expect(decoded.executablePath == request.executablePath)
        #expect(decoded.arguments == request.arguments)
        #expect(decoded.environment == request.environment)
        #expect(decoded.stdinData == request.stdinData)
        #expect(decoded.timeoutSeconds == request.timeoutSeconds)
    }

    @Test func responseRoundTripsThroughJSON() throws {
        let response = DockerRunResponse(
            stdout: Data("ok".utf8),
            stderr: Data(),
            exitCode: 0,
            timedOut: false,
            launchError: nil,
            logs: ["started", "finished"]
        )
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(DockerRunResponse.self, from: data)
        #expect(decoded.stdout == response.stdout)
        #expect(decoded.exitCode == 0)
        #expect(decoded.logs == response.logs)
    }
}
