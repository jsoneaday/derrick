import Foundation
import Testing
@testable import Structure

@Suite struct DockerWorkerDockerfileTests {
    @Test func dockerfilePinsLabeledWorkerUserAndCurrentGolang() throws {
        let dockerfile = repoRoot()
            .appendingPathComponent("docker/worker/Dockerfile", isDirectory: false)
        let text = try String(contentsOf: dockerfile, encoding: .utf8)
        #expect(text.contains("FROM golang:1.27.1"))
        #expect(text.contains("USER worker"))
        #expect(text.contains("LABEL \(DockerWorkerRuntime.binariesLabelKey)=\"\(DockerWorkerRuntime.binariesLabelValue)\""))
    }

    @Test func pruneScriptRemovesUnlabeledWorkerImagesAndOldGolangTags() throws {
        let script = repoRoot()
            .appendingPathComponent("scripts/prune-dangling-worker-images.sh", isDirectory: false)
        let text = try String(contentsOf: script, encoding: .utf8)
        #expect(text.contains("Config.User"))
        #expect(text.contains("\"worker\""))
        #expect(text.contains("derrick.worker.binaries"))
        #expect(text.contains("docker rmi \"golang:${tag}\""))
        #expect(text.contains("Keep the live derrick-worker tag"))
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
