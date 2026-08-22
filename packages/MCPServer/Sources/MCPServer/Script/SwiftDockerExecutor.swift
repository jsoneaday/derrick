import Foundation
import DockerRunnerXPC
import Plugin
import ServiceContracts

/// Shared Swift source, compiler, and artifact executor for all generated code.
/// Every operation runs in the pinned Swift image with no network access.
public struct SwiftDockerExecutor: Sendable {
    public let image: String
    private let executor: DockerCLIExecutor

    public init(
        image: String = DerrickGuestRuntime.swiftPluginDockerImage,
        executor: @escaping DockerCLIExecutor
    ) {
        self.image = image.trimmingCharacters(in: .whitespacesAndNewlines)
        self.executor = executor
    }

    public func runSource(
        source: String,
        input: Data
    ) async throws -> PluginFactoryExecutionResult {
        try await withSwiftContainer { name in
            try await write(source: Data(source.utf8), to: name)
            return result(
                from: try await executor(
                    ["exec", "-i", name, "swift", "/tmp/plugin.swift"],
                    input,
                    300
                )
            )
        }
    }

    public func compile(source: String) async throws -> Data {
        try await withSwiftContainer { name in
            try await write(source: Data(source.utf8), to: name)
            try check(
                try await executor(
                    ["exec", name, "swiftc", "-O", "/tmp/plugin.swift", "-o", "/tmp/plugin"],
                    Data(),
                    600
                ),
                step: "swiftc"
            )
            let encoded = try await executor(
                ["exec", name, "base64", "-w", "0", "/tmp/plugin"],
                Data(),
                600
            )
            try check(encoded, step: "read compiled artifact")
            guard let artifact = Data(base64Encoded: encoded.stdout) else {
                throw SwiftDockerExecutorError.invalidArtifact
            }
            return artifact
        }
    }

    public func runArtifact(
        _ artifact: Data,
        input: Data,
        timeoutSeconds: Int = 300
    ) async throws -> PluginFactoryExecutionResult {
        try await withSwiftContainer { name in
            try await write(source: artifact, to: name, path: "/tmp/plugin")
            try check(
                try await executor(
                    ["exec", name, "chmod", "700", "/tmp/plugin"],
                    Data(),
                    30
                ),
                step: "prepare compiled artifact"
            )
            return result(
                from: try await executor(
                    ["exec", "-i", name, "/tmp/plugin"],
                    input,
                    min(max(timeoutSeconds, 1), 300)
                )
            )
        }
    }

    private func withSwiftContainer<T: Sendable>(
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
        let name = "\(SwiftScriptPreparer.containerPrefix)-\(UUID().uuidString.lowercased())"
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
            step: "create Swift runtime container"
        )
        do {
            try check(
                try await executor(["start", name], Data(), 30),
                step: "start Swift runtime container"
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

    private func write(
        source: Data,
        to container: String,
        path: String = "/tmp/plugin.swift"
    ) async throws {
        try check(
            try await executor(
                ["exec", "-i", container, "sh", "-c", "cat > \(path)"],
                source,
                60
            ),
            step: "write Swift source"
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
            throw SwiftDockerExecutorError.commandFailed(
                step,
                detail.isEmpty ? "exit \(response.exitCode)" : detail
            )
        }
    }

    private func remove(_ name: String) async {
        _ = try? await executor(["rm", "-f", name], Data(), 30)
    }
}

public enum SwiftDockerExecutorError: Error, LocalizedError, Equatable, Sendable {
    case commandFailed(String, String)
    case invalidArtifact

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let step, let detail):
            return "\(step) failed: \(detail)"
        case .invalidArtifact:
            return "swiftc returned an invalid compiled artifact."
        }
    }
}
