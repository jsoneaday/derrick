import Foundation
import Structure

/// Runs the prebuilt search binary in a oneshot container: create, exec, rm.
/// Own queue. Image pull/build stays outside the permit.
///
/// The image is trusted product code. User input is passed only as JSON on
/// stdin; it is never interpolated into a shell command.
public struct WebSearchDockerExecutor: Sendable {
    public static let image = DockerWorkerRuntime.image
    public static let containerPrefix = "derrick-web-search"
    public static let binaryPath = DockerWorkerRuntime.searchBinary
    public static let maximumTimeoutSeconds = 60
    public static let dockerNetwork = "bridge"
    public static let searchHosts = DockerWorkerRuntime.searchHosts

    private let executor: DockerCLIExecutor
    private let queue: DerrickDockerRunQueue
    public init(
        executor: @escaping DockerCLIExecutor,
        queue: DerrickDockerRunQueue = .search
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
        let executor = self.executor
        do {
            return try await queue.withPermit {
                let proxyLease = try await WebCrawlerEgressProxy.shared.lease(forHosts: Self.searchHosts)
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
                        createStep: "create search container",
                        startStep: "start search container",
                        body: { name in
                            try await executor(
                                ["exec", "-i", name, Self.binaryPath],
                                input,
                                timeout
                            )
                        }
                    )
                    await WebCrawlerEgressProxy.shared.release(forHosts: Self.searchHosts)
                    return result
                } catch {
                    await WebCrawlerEgressProxy.shared.release(forHosts: Self.searchHosts)
                    throw error
                }
            }
        } catch let error as OneshotDockerContainerError {
            throw mappedSearchError(error)
        }
    }

    /// Idle-container create argv. The worker image has no ENTRYPOINT/CMD, so
    /// PID 1 is `/bin/sleep` until `docker exec` runs the search binary.
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
            "--pids-limit", "64",
            "--cpus", "1.0",
            "--memory", "256m",
            "--name", name,
            "--env", "DERRICK_EGRESS_PROXY_HOST=\(proxyHost)",
            "--env", "DERRICK_EGRESS_PROXY_PORT=\(proxyPort)",
            "--env", "DERRICK_EGRESS_PROXY_TOKEN=\(proxyToken)",
            "--entrypoint", "/bin/sleep",
            image,
            "infinity"
        ]
    }

    private func mappedSearchError(_ error: OneshotDockerContainerError) -> Error {
        switch error {
        case .commandFailed(let step, let detail):
            return WebSearchDockerExecutorError.commandFailed(step, detail)
        case .imageUnavailable(let detail):
            return WebSearchDockerExecutorError.imageUnavailable(detail)
        }
    }
}

public enum WebSearchDockerExecutorError: Error, LocalizedError, Sendable, Equatable {
    case commandFailed(String, String)
    case imageUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let step, let detail):
            return "\(step) failed: \(detail)"
        case .imageUnavailable(let image):
            return "Search image is not installed: \(image)."
        }
    }
}
