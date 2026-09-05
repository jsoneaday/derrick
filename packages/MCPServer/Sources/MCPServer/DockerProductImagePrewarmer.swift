import Foundation
import DockerRunnerXPC
import Structure

/// Ensures trusted product Docker images exist (pull or local build).
public enum DockerProductImagePrewarmer: Sendable {
    public static func ensureWebCrawlerImage(
        executor: @escaping DockerCLIExecutor
    ) async throws {
        try await ensureImage(
            tag: DockerProductImagePolicy.webCrawlerImage,
            dockerfileRelativePath: DockerProductImagePolicy.webCrawlerDockerfileRelativePath,
            executor: executor,
            buildTimeoutSeconds: 1_200
        )
    }

    public static func ensureImage(
        tag: String,
        dockerfileRelativePath: String,
        executor: @escaping DockerCLIExecutor,
        buildTimeoutSeconds: Int = 1_200
    ) async throws {
        let inspect = try await executor(["image", "inspect", tag], Data(), 30)
        if inspect.exitCode == 0 {
            return
        }

        guard let repoRoot = DerrickRepositoryRoot.locate() else {
            throw DockerProductImagePrewarmerError.repositoryRootNotFound(tag)
        }
        let dockerfile = repoRoot.appendingPathComponent(dockerfileRelativePath)
        guard FileManager.default.fileExists(atPath: dockerfile.path) else {
            throw DockerProductImagePrewarmerError.dockerfileMissing(dockerfile.path)
        }

        let build = try await executor(
            [
                "build",
                "-f", dockerfile.path,
                "-t", tag,
                repoRoot.path,
            ],
            Data(),
            buildTimeoutSeconds
        )
        guard build.exitCode == 0 else {
            let detail = String(decoding: build.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw DockerProductImagePrewarmerError.buildFailed(
                tag,
                detail.isEmpty ? "exit \(build.exitCode)" : detail
            )
        }
    }
}

public enum DockerProductImagePrewarmerError: Error, LocalizedError, Equatable, Sendable {
    case repositoryRootNotFound(String)
    case dockerfileMissing(String)
    case buildFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .repositoryRootNotFound(let tag):
            return "Docker image \(tag) is not installed and the Derrick source tree could not be found to build it."
        case .dockerfileMissing(let path):
            return "Docker image build failed: missing Dockerfile at \(path)."
        case .buildFailed(let tag, let detail):
            return "Docker image build failed for \(tag): \(detail)"
        }
    }
}
