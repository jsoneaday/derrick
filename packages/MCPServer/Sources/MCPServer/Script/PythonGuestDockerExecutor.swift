import Foundation
import DockerRunnerXPC
import Plugin
import Structure

/// Offline Python guest executor for script_exec and future plugin.invoke paths.
public struct PythonGuestDockerExecutor: Sendable {
    public static let containerPrefix = "derrick-guest-runtime"

    public let image: String
    private let executor: DockerCLIExecutor

    public init(
        image: String = DerrickGuestRuntime.pythonGuestDockerImage,
        executor: @escaping DockerCLIExecutor
    ) {
        self.image = image.trimmingCharacters(in: .whitespacesAndNewlines)
        self.executor = executor
    }

    public func runSource(
        source: String,
        input: Data,
        timeoutSeconds: Int = 300
    ) async throws -> PluginFactoryExecutionResult {
        try await withGuestContainer { name in
            try await write(source: Data(source.utf8), to: name)
            return result(
                from: try await executor(
                    ["exec", "-i", name, "python3", "/tmp/guest.py"],
                    input,
                    min(max(timeoutSeconds, 1), SwiftScriptPreparer.maxTimeoutSeconds)
                )
            )
        }
    }

    private func withGuestContainer<T: Sendable>(
        _ body: @escaping @Sendable (String) async throws -> T
    ) async throws -> T {
        try await ensureImage()
        return try await SwiftDockerContainerPool.shared.withPermit {
            try await self.createAndRunContainer(body)
        }
    }

    private func createAndRunContainer<T: Sendable>(
        _ body: @escaping @Sendable (String) async throws -> T
    ) async throws -> T {
        let name = "\(Self.containerPrefix)-\(UUID().uuidString.lowercased())"
        try check(
            try await executor(
                [
                    "create",
                    "--network", "none",
                    "--name", name,
                    "--env", "HOME=/tmp",
                    "--read-only",
                    "--tmpfs", "/tmp:rw,exec,nosuid,size=128m",
                    "--pids-limit", "128",
                    "--cpus", "2.0",
                    "--memory", "1g",
                    "--security-opt", "no-new-privileges",
                    "--cap-drop", "ALL",
                    image,
                    "/bin/sleep",
                    "infinity",
                ],
                Data(),
                60
            ),
            step: "create guest runtime container"
        )
        do {
            try check(
                try await executor(["start", name], Data(), 30),
                step: "start guest runtime container"
            )
            let value = try await body(name)
            await remove(name)
            return value
        } catch {
            await remove(name)
            throw error
        }
    }

    private func ensureImage() async throws {
        try await SwiftDockerContainerPool.shared.prewarm(
            image: image,
            executor: executor
        )
    }

    private func write(source: Data, to container: String) async throws {
        try check(
            try await executor(
                ["exec", "-i", container, "sh", "-c", "cat > /tmp/guest.py"],
                source,
                60
            ),
            step: "write Python source"
        )
    }

    private func result(from response: DockerCLIResult) -> PluginFactoryExecutionResult {
        PluginFactoryExecutionResult(
            exitCode: response.exitCode,
            stdout: response.stdout,
            stderr: response.stderr
        )
    }

    private func check(_ response: DockerCLIResult, step: String) throws {
        guard response.exitCode == 0 else {
            let detail = String(decoding: response.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw PythonGuestDockerExecutorError.commandFailed(
                step,
                detail.isEmpty ? "exit \(response.exitCode)" : detail
            )
        }
    }

    private func remove(_ name: String) async {
        _ = try? await executor(["rm", "-f", name], Data(), 30)
    }
}

public enum PythonGuestDockerExecutorError: Error, LocalizedError, Equatable, Sendable {
    case commandFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let step, let detail):
            return "\(step) failed: \(detail)"
        }
    }
}
