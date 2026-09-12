import Foundation
import DockerRunnerXPC
import Structure

/// Ensures trusted product Docker images exist (local build) and match pinned digests.
public enum DockerProductImagePrewarmer: Sendable {
    public static func ensureWorkerImage(
        executor: @escaping DockerCLIExecutor
    ) async throws {
        try await ensureImage(
            tag: DockerProductImagePolicy.workerImage,
            dockerfileRelativePath: DockerProductImagePolicy.workerDockerfileRelativePath,
            contextRelativePath: DockerProductImagePolicy.workerBuildContextRelativePath,
            pinnedDigest: DockerWorkerRuntime.pinnedDigest,
            buildValidator: DockerProductImagePolicy.isAllowedWorkerBuild,
            executor: executor,
            buildTimeoutSeconds: 1_200
        )
    }

    /// Legacy alias used by crawler startup paths.
    public static func ensureWebCrawlerImage(
        executor: @escaping DockerCLIExecutor
    ) async throws {
        try await ensureWorkerImage(executor: executor)
    }

    public static func ensureImage(
        tag: String,
        dockerfileRelativePath: String,
        contextRelativePath: String,
        pinnedDigest: DockerImageDigest,
        buildValidator: @escaping (String, String, String) -> Bool,
        executor: @escaping DockerCLIExecutor,
        buildTimeoutSeconds: Int = 1_200
    ) async throws {
        let inspect = try await executor(["image", "inspect", tag], Data(), 30)
        if inspect.exitCode == 0 {
            let binariesCurrent = await DockerImageInspector.workerImageHasCurrentBinaries(
                tag: tag,
                executor: executor
            )
            if binariesCurrent {
                try await DockerImageInspector.verifyPinned(
                    tag: tag,
                    expected: pinnedDigest,
                    executor: executor
                )
                return
            }
            // Stale worker image (missing required binaries). Rebuild overwrites the tag.
        }

        guard let repoRoot = DerrickRepositoryRoot.locate() else {
            throw DockerProductImagePrewarmerError.repositoryRootNotFound(tag)
        }
        let dockerfile = repoRoot.appendingPathComponent(dockerfileRelativePath)
        guard FileManager.default.fileExists(atPath: dockerfile.path) else {
            throw DockerProductImagePrewarmerError.dockerfileMissing(dockerfile.path)
        }
        let context = repoRoot.appendingPathComponent(contextRelativePath)
        guard FileManager.default.fileExists(atPath: context.path) else {
            throw DockerProductImagePrewarmerError.dockerfileMissing(context.path)
        }
        guard buildValidator(dockerfile.path, tag, context.path) else {
            throw DockerProductImagePrewarmerError.buildFailed(tag, "build policy rejected image build")
        }

        let build = try await executor(
            [
                "build",
                "-f", dockerfile.path,
                "-t", tag,
                context.path,
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

        try await DockerImageInspector.verifyPinned(
            tag: tag,
            expected: pinnedDigest,
            executor: executor
        )
    }
}

/// Legacy alias gate — delegates to `WorkerImageGate` so crawler/script paths share one build.
public actor WebCrawlerImageGate {
    public static let shared = WebCrawlerImageGate()

    public init() {}

    public func ensureReady(executor: @escaping DockerCLIExecutor) async throws {
        try await WorkerImageGate.shared.ensureReady(executor: executor)
    }
}

public enum DockerProductImagePrewarmerError: Error, LocalizedError, Equatable, Sendable {
    case repositoryRootNotFound(String)
    case dockerfileMissing(String)
    case buildFailed(String, String)

    public var compilerDiagnostic: String? {
        switch self {
        case .buildFailed(_, let detail):
            return Self.compilerDiagnostic(from: detail)
        case .repositoryRootNotFound, .dockerfileMissing:
            return nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .repositoryRootNotFound:
            return "The worker image is not installed and Derrick could not find its source to build it."
        case .dockerfileMissing:
            return "The worker image is not installed and Derrick could not find its build files."
        case .buildFailed:
            return "Derrick could not build the worker image. Make sure Docker Desktop is running, has enough disk space, and can reach the network."
        }
    }

    public static func compilerDiagnostic(from detail: String) -> String? {
        let stripped = detail.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*m",
            with: "",
            options: .regularExpression
        )
        for line in stripped.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("error:"), !trimmed.hasPrefix("#") else { continue }
            return String(trimmed.prefix(240))
        }
        return nil
    }
}
