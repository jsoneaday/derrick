import Foundation
import Structure

/// Runs the prebuilt crawler image in a oneshot container: create, exec, rm.
/// Own queue (max 2). Image pull/build stays outside the permit.
///
/// The image is trusted product code. User input is passed only as JSON on
/// stdin; it is never interpolated into a shell command.
public struct WebCrawlerDockerExecutor: Sendable {
    public static let image = "derrick-web-crawler:swift-6.4-v1"
    public static let containerPrefix = "derrick-web-crawler"
    public static let maximumTimeoutSeconds = 900
    public static let dockerNetwork = "bridge"

    private let executor: DockerCLIExecutor
    private let queue: DerrickDockerRunQueue
    private let imageGate: WebCrawlerImageGate

    public init(
        executor: @escaping DockerCLIExecutor,
        queue: DerrickDockerRunQueue = .crawler,
        imageGate: WebCrawlerImageGate = .shared
    ) {
        self.executor = executor
        self.queue = queue
        self.imageGate = imageGate
    }

    public func run(
        input: Data,
        timeoutSeconds: Int
    ) async throws -> DockerCLIResult {
        let timeout = min(max(timeoutSeconds, 1), Self.maximumTimeoutSeconds)
        try await imageGate.ensureReady(executor: executor)
        let prepared = try await WebCrawlerDockerInputPreparer.enrich(input)
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
                        createStep: "create crawler container",
                        startStep: "start crawler container",
                        body: { name in
                            try await executor(
                                ["exec", "-i", name, "/usr/local/bin/derrick-web-crawler"],
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
            throw mappedCrawlerError(error)
        }
    }

    /// Idle-container create argv. The image ENTRYPOINT is the crawler binary,
    /// so PID 1 must override it with sleep or the container exits before exec.
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
            "infinity"
        ]
    }

    private func mappedCrawlerError(_ error: OneshotDockerContainerError) -> Error {
        switch error {
        case .commandFailed(let step, let detail):
            return WebCrawlerDockerExecutorError.commandFailed(step, detail)
        case .imageUnavailable(let detail):
            return WebCrawlerDockerExecutorError.imageUnavailable(detail)
        }
    }
}

public enum WebCrawlerDockerExecutorError: Error, LocalizedError, Sendable, Equatable {
    case commandFailed(String, String)
    case imageUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let step, let detail):
            return "\(step) failed: \(detail)"
        case .imageUnavailable(let image):
            return "Crawler image is not installed: \(image)."
        }
    }
}
