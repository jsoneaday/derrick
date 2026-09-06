import Foundation
import Plugin
import Structure

/// Offline Python guest executor for script_exec and plugin.invoke.
///
/// Recreate-on-handoff: one fresh `--network none` container per run, deleted
/// when the hop loop finishes (host done). The image is reused if already pulled.
public struct PythonGuestDockerExecutor: Sendable {
    public static let containerPrefix = "derrick-guest-runtime"

    public let image: String
    private let executor: DockerCLIExecutor
    private let queue: DerrickDockerRunQueue

    public init(
        image: String = DerrickGuestRuntime.pythonGuestDockerImage,
        executor: @escaping DockerCLIExecutor,
        queue: DerrickDockerRunQueue = .guest
    ) {
        self.image = image.trimmingCharacters(in: .whitespacesAndNewlines)
        self.executor = executor
        self.queue = queue
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
                    min(max(timeoutSeconds, 1), GuestRuntimeLimits.maxTimeoutSeconds)
                )
            )
        }
    }

    private func withGuestContainer<T: Sendable>(
        _ body: @escaping @Sendable (String) async throws -> T
    ) async throws -> T {
        try await OneshotDockerContainer.ensurePulledImage(image, executor: executor)
        let image = self.image
        let executor = self.executor
        do {
            return try await queue.withPermit {
                try await OneshotDockerContainer.run(
                    executor: executor,
                    prefix: Self.containerPrefix,
                    createArguments: { name in
                        [
                            "create",
                        ] + DerrickDockerRuntimeIdentity.createLabelArguments + [
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
                        ]
                    },
                    createStep: "create guest runtime container",
                    startStep: "start guest runtime container",
                    body: body
                )
            }
        } catch let error as OneshotDockerContainerError {
            throw mappedGuestError(error)
        }
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
            throw PythonGuestDockerExecutorError.commandFailed(step, detail(from: response))
        }
    }

    private func mappedGuestError(_ error: OneshotDockerContainerError) -> Error {
        switch error {
        case .commandFailed(let step, let detail):
            return PythonGuestDockerExecutorError.commandFailed(step, detail)
        case .imageUnavailable:
            return error
        }
    }

    private func detail(from result: DockerCLIResult) -> String {
        let stderr = String(decoding: result.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stderr.isEmpty ? "exit \(result.exitCode)" : stderr
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
