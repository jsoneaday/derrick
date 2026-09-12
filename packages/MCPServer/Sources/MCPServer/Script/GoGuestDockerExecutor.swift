import Foundation
import Plugin
import Structure

/// Offline Go guest executor for `script_exec` and `plugin.invoke`.
///
/// Compiles `package main` source and runs the Linux binary inside the pinned
/// worker image. Untrusted source never touches the host toolchain.
public struct GoGuestDockerExecutor: Sendable {
    public static let containerPrefix = "derrick-guest-runtime"
    private static let compileTimeoutSeconds = 120
    private static let writeTimeoutSeconds = 60

    public let image: String
    private let executor: DockerCLIExecutor
    private let queue: DerrickDockerRunQueue

    public init(
        image: String = DockerWorkerRuntime.image,
        executor: @escaping DockerCLIExecutor,
        queue: DerrickDockerRunQueue = .guest
    ) {
        self.image = image.trimmingCharacters(in: .whitespacesAndNewlines)
        self.executor = executor
        self.queue = queue
    }

    /// Compile guest source in a one-shot container and return the Linux binary bytes.
    public func compileSource(_ source: String) async throws -> Data {
        try await WorkerImageGate.shared.ensureReady(executor: executor)
        return try await withGuestContainer { name in
            try await prepareCompiledGuest(source: source, in: name)
            return try await readBinary(from: name)
        }
    }

    /// Compile once, run once (factory single-hop path).
    public func runSource(
        source: String,
        input: Data,
        timeoutSeconds: Int = 300
    ) async throws -> PluginFactoryExecutionResult {
        try await withCompiledGuest(source: source) { name in
            try await runCompiledGuest(
                container: name,
                input: input,
                timeoutSeconds: timeoutSeconds
            )
        }
    }

    /// Compile once, then run the body with a live container name (multi-hop loops).
    public func withCompiledGuest<T: Sendable>(
        source: String,
        _ body: @escaping @Sendable (String) async throws -> T
    ) async throws -> T {
        try await WorkerImageGate.shared.ensureReady(executor: executor)
        return try await withGuestContainer { name in
            try await prepareCompiledGuest(source: source, in: name)
            return try await body(name)
        }
    }

    /// Run a previously compiled guest binary in a one-shot container.
    public func runArtifact(
        artifact: Data,
        input: Data,
        timeoutSeconds: Int = 300
    ) async throws -> PluginFactoryExecutionResult {
        try await WorkerImageGate.shared.ensureReady(executor: executor)
        return try await withGuestContainer { name in
            try await write(binary: artifact, to: name)
            return try await runCompiledGuest(
                container: name,
                input: input,
                timeoutSeconds: timeoutSeconds
            )
        }
    }

    /// Execute `/tmp/guest` in an existing guest container.
    public func runCompiledGuest(
        container name: String,
        input: Data,
        timeoutSeconds: Int = 300
    ) async throws -> PluginFactoryExecutionResult {
        result(
            from: try await executor(
                [
                    "exec", "-i", name,
                    DockerWorkerRuntime.guestBinaryPath,
                ],
                input,
                min(max(timeoutSeconds, 1), GuestRuntimeLimits.maxTimeoutSeconds)
            )
        )
    }

    private func prepareCompiledGuest(source: String, in container: String) async throws {
        try await writeSource(source, to: container)
        try await compileGuest(in: container)
    }

    private func withGuestContainer<T: Sendable>(
        _ body: @escaping @Sendable (String) async throws -> T
    ) async throws -> T {
        try await DockerImageInspector.verifyPinned(
            tag: image,
            expected: DockerWorkerRuntime.pinnedDigest,
            executor: executor
        )
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
                            "--env", "GOCACHE=/tmp/gocache",
                            "--env", "GOTMPDIR=/tmp",
                            "--read-only",
                            "--tmpfs", "/tmp:rw,exec,nosuid,size=256m",
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
                    createStep: "create go guest runtime container",
                    startStep: "start go guest runtime container",
                    body: body
                )
            }
        } catch let error as OneshotDockerContainerError {
            throw mappedGuestError(error)
        }
    }

    private func writeSource(_ source: String, to container: String) async throws {
        try check(
            try await executor(
                ["exec", "-i", container, "sh", "-c", DockerWorkerRuntime.guestWriteSourceShell],
                Data(source.utf8),
                Self.writeTimeoutSeconds
            ),
            step: "write Go guest source"
        )
    }

    private func write(binary: Data, to container: String) async throws {
        try check(
            try await executor(
                [
                    "exec", "-i", container, "sh", "-c",
                    "cat > \(DockerWorkerRuntime.guestBinaryPath) && chmod +x \(DockerWorkerRuntime.guestBinaryPath)",
                ],
                binary,
                Self.writeTimeoutSeconds
            ),
            step: "write Go guest binary"
        )
    }

    private func compileGuest(in container: String) async throws {
        try check(
            try await executor(
                ["exec", container, "sh", "-c", DockerWorkerRuntime.guestCompileShell],
                Data(),
                Self.compileTimeoutSeconds
            ),
            step: "compile Go guest"
        )
    }

    private func readBinary(from container: String) async throws -> Data {
        let response = try await executor(
            ["exec", container, "sh", "-c", DockerWorkerRuntime.guestReadBinaryShell],
            Data(),
            Self.writeTimeoutSeconds
        )
        try check(response, step: "read compiled Go guest")
        guard !response.stdout.isEmpty else {
            throw GoGuestDockerExecutorError.commandFailed(
                "read compiled Go guest",
                "compiled binary was empty"
            )
        }
        return response.stdout
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
            throw GoGuestDockerExecutorError.commandFailed(step, detail(from: response))
        }
    }

    private func mappedGuestError(_ error: OneshotDockerContainerError) -> Error {
        switch error {
        case .commandFailed(let step, let detail):
            return GoGuestDockerExecutorError.commandFailed(step, detail)
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

public enum GoGuestDockerExecutorError: Error, LocalizedError, Equatable, Sendable {
    case commandFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let step, let detail):
            return "\(step) failed: \(detail)"
        }
    }
}

/// Shared gate for worker image readiness (crawl, extract, plugin guest).
public actor WorkerImageGate {
    public static let shared = WorkerImageGate()

    private var inFlight: Task<Void, Error>?

    public func ensureReady(executor: @escaping DockerCLIExecutor) async throws {
        if let inFlight {
            try await inFlight.value
            return
        }
        let task = Task {
            try await DockerProductImagePrewarmer.ensureWorkerImage(executor: executor)
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
