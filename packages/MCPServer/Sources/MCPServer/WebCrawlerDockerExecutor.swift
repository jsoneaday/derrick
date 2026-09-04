import Foundation
import ServiceContracts
import WebCrawler

/// Runs the prebuilt crawler image in a fresh, resource-limited container.
///
/// The image is trusted product code. User input is passed only as JSON on
/// stdin; it is never interpolated into a shell command.
public struct WebCrawlerDockerExecutor: Sendable {
    public static let image = "derrick-web-crawler:swift-6.4-v1"
    public static let containerPrefix = "derrick-web-crawler"
    public static let maximumTimeoutSeconds = 900
    public static let dockerNetwork = "bridge"

    private let executor: DockerCLIExecutor

    public init(
        executor: @escaping DockerCLIExecutor
    ) {
        self.executor = executor
    }

    public func run(
        input: Data,
        timeoutSeconds: Int
    ) async throws -> DockerCLIResult {
        let timeout = min(max(timeoutSeconds, 1), Self.maximumTimeoutSeconds)
        try await DockerProductImagePrewarmer.ensureWebCrawlerImage(executor: executor)
        let prepared = try await WebCrawlerDockerInputPreparer.enrich(input)
        let name = "\(Self.containerPrefix)-\(UUID().uuidString.lowercased())"
        let proxyLease = try await WebCrawlerEgressProxy.shared.lease(forHosts: prepared.leaseHosts)
        let createArguments = Self.createArguments(
            name: name,
            proxyHost: proxyLease.host,
            proxyPort: proxyLease.port,
            proxyToken: proxyLease.clientToken
        )

        do {
            let created = try await executor(createArguments, Data(), 60)
            guard created.exitCode == 0 else {
                throw WebCrawlerDockerExecutorError.commandFailed(
                    "create crawler container",
                    detail(from: created)
                )
            }

            let started = try await executor(["start", name], Data(), 30)
            guard started.exitCode == 0 else {
                throw WebCrawlerDockerExecutorError.commandFailed(
                    "start crawler container",
                    detail(from: started)
                )
            }

            let result = try await executor(
                ["exec", "-i", name, "/usr/local/bin/derrick-web-crawler"],
                prepared.data,
                timeout
            )
            await remove(name)
            await WebCrawlerEgressProxy.shared.release(forHosts: prepared.leaseHosts)
            return result
        } catch {
            await remove(name)
            await WebCrawlerEgressProxy.shared.release(forHosts: prepared.leaseHosts)
            throw error
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

    private func remove(_ name: String) async {
        _ = try? await executor(["rm", "-f", name], Data(), 30)
    }

    private func detail(from result: DockerCLIResult) -> String {
        let stderr = String(decoding: result.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stderr.isEmpty ? "exit \(result.exitCode)" : stderr
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
