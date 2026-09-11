import Foundation
import Structure

/// Runs the prebuilt news reader in a oneshot container: create, exec, rm.
public struct NewsReaderDockerExecutor: Sendable {
    public static let image = DockerWorkerRuntime.image
    public static let containerPrefix = "derrick-news-reader"
    public static let binaryPath = DockerWorkerRuntime.newsReaderBinary
    public static let maximumTimeoutSeconds = 300
    public static let dockerNetwork = "bridge"

    private let executor: DockerCLIExecutor
    private let queue: DerrickDockerRunQueue

    public init(
        executor: @escaping DockerCLIExecutor,
        queue: DerrickDockerRunQueue = .crawler
    ) {
        self.executor = executor
        self.queue = queue
    }

    public func run(
        input: Data,
        timeoutSeconds: Int
    ) async throws -> DockerCLIResult {
        let timeout = min(max(timeoutSeconds, 1), Self.maximumTimeoutSeconds)
        try await WorkerImageGate.shared.ensureReady(executor: executor)
        let prepared = try await NewsReaderDockerInputPreparer.enrich(input)
        let executor = self.executor
        do {
            return try await queue.withPermit {
                let proxyLease = try await WebCrawlerEgressProxy.shared.lease(forHosts: prepared.leaseHosts)
                do {
                    let result = try await OneshotDockerContainer.run(
                        executor: executor,
                        prefix: Self.containerPrefix,
                        createArguments: { name in
                            Self.createArguments(
                                name: name,
                                proxyHost: proxyLease.host,
                                proxyPort: proxyLease.port,
                                proxyToken: proxyLease.clientToken
                            )
                        },
                        createStep: "create news reader container",
                        startStep: "start news reader container",
                        body: { name in
                            try await executor(
                                ["exec", "-i", name, Self.binaryPath],
                                prepared.data,
                                timeout
                            )
                        }
                    )
                    await WebCrawlerEgressProxy.shared.release(forHosts: prepared.leaseHosts)
                    return result
                } catch {
                    await WebCrawlerEgressProxy.shared.release(forHosts: prepared.leaseHosts)
                    throw error
                }
            }
        } catch let error as OneshotDockerContainerError {
            throw mappedNewsReaderError(error)
        }
    }

    static func createArguments(
        name: String,
        proxyHost: String,
        proxyPort: Int,
        proxyToken: String
    ) -> [String] {
        [
            "create",
        ] + DerrickDockerRuntimeIdentity.createLabelArguments + [
            "--network", dockerNetwork,
            "--read-only",
            "--tmpfs", "/tmp:rw,exec,nosuid,size=64m",
            "--pids-limit", "128",
            "--cpus", "1.0",
            "--memory", "512m",
            "--name", name,
            "--env", "DERRICK_EGRESS_PROXY_HOST=\(proxyHost)",
            "--env", "DERRICK_EGRESS_PROXY_PORT=\(proxyPort)",
            "--env", "DERRICK_EGRESS_PROXY_TOKEN=\(proxyToken)",
            "--entrypoint", "/bin/sleep",
            image,
            "infinity",
        ]
    }

    private func mappedNewsReaderError(_ error: OneshotDockerContainerError) -> Error {
        switch error {
        case .commandFailed(let step, let detail):
            return NewsReaderDockerExecutorError.commandFailed(step, detail)
        case .imageUnavailable(let detail):
            return NewsReaderDockerExecutorError.imageUnavailable(detail)
        }
    }
}

public enum NewsReaderDockerExecutorError: Error, LocalizedError, Sendable, Equatable {
    case commandFailed(String, String)
    case imageUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let step, let detail):
            return "\(step) failed: \(detail)"
        case .imageUnavailable(let image):
            return "News reader image is not installed: \(image)."
        }
    }
}
