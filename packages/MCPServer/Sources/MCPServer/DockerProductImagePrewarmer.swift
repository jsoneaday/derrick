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
            contextRelativePath: DockerProductImagePolicy.webCrawlerBuildContextRelativePath,
            executor: executor,
            buildTimeoutSeconds: 1_200
        )
    }

    public static func ensureImage(
        tag: String,
        dockerfileRelativePath: String,
        contextRelativePath: String,
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
        let context = repoRoot.appendingPathComponent(contextRelativePath)
        guard FileManager.default.fileExists(atPath: context.path) else {
            throw DockerProductImagePrewarmerError.dockerfileMissing(context.path)
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
    }
}

/// One in-flight crawler image build per process.
///
/// Chat and daemon start this in the background. A `web.crawl` that arrives
/// while it is still running waits on the same task and does not start a second
/// `docker build`.
public actor WebCrawlerImageGate {
    public static let shared = WebCrawlerImageGate()

    private var inFlight: Task<Void, Error>?

    public init() {}

    public func ensureReady(executor: @escaping DockerCLIExecutor) async throws {
        if let inFlight {
            try await inFlight.value
            return
        }
        let task = Task {
            try await DockerProductImagePrewarmer.ensureWebCrawlerImage(executor: executor)
        }
        inFlight = task
        do {
            try await task.value
            inFlight = nil
        } catch {
            inFlight = nil
            throw error
        }
    }
}

public enum DockerProductImagePrewarmerError: Error, LocalizedError, Equatable, Sendable {
    case repositoryRootNotFound(String)
    case dockerfileMissing(String)
    case buildFailed(String, String)

    /// First compiler `error:` line, if the docker build log has one. Not shown as the
    /// user-facing `errorDescription` (that stays a short human sentence).
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
            return "The web crawler image is not installed and Derrick could not find its source to build it."
        case .dockerfileMissing:
            return "The web crawler image is not installed and Derrick could not find its build files."
        case .buildFailed:
            return "Derrick could not build the web crawler image. Make sure Docker Desktop is running, has enough disk space, and can reach the network."
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
