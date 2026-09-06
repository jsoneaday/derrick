import Foundation
import Structure

/// Recreate-on-handoff helpers: cached image, fresh container, always `docker rm -f`.
public enum OneshotDockerContainer: Sendable {
    public static func ensurePulledImage(
        _ image: String,
        executor: @escaping DockerCLIExecutor
    ) async throws {
        let inspect = try await executor(["image", "inspect", image], Data(), 30)
        guard inspect.exitCode != 0 else { return }
        let pulled = try await executor(["pull", image], Data(), 1_200)
        guard pulled.exitCode == 0 else {
            let detail = String(decoding: pulled.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw OneshotDockerContainerError.imageUnavailable(
                detail.isEmpty ? "exit \(pulled.exitCode)" : detail
            )
        }
    }

    public static func run<T: Sendable>(
        executor: @escaping DockerCLIExecutor,
        prefix: String,
        createArguments: @escaping @Sendable (String) -> [String],
        createStep: String,
        startStep: String,
        body: @escaping @Sendable (String) async throws -> T
    ) async throws -> T {
        let name = "\(prefix)-\(UUID().uuidString.lowercased())"
        do {
            try check(
                try await executor(createArguments(name), Data(), 60),
                step: createStep
            )
            try check(
                try await executor(["start", name], Data(), 30),
                step: startStep
            )
            let value = try await body(name)
            await remove(name, executor: executor)
            return value
        } catch {
            await remove(name, executor: executor)
            throw error
        }
    }

    public static func remove(
        _ name: String,
        executor: @escaping DockerCLIExecutor
    ) async {
        _ = try? await executor(["rm", "-f", name], Data(), 30)
    }

    private static func check(_ response: DockerCLIResult, step: String) throws {
        guard response.exitCode == 0 else {
            throw OneshotDockerContainerError.commandFailed(step, detail(from: response))
        }
    }

    private static func detail(from result: DockerCLIResult) -> String {
        let stderr = String(decoding: result.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stderr.isEmpty ? "exit \(result.exitCode)" : stderr
    }
}

public enum OneshotDockerContainerError: Error, LocalizedError, Equatable, Sendable {
    case commandFailed(String, String)
    case imageUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let step, let detail):
            return "\(step) failed: \(detail)"
        case .imageUnavailable(let detail):
            return "Guest runtime image is unavailable: \(detail)"
        }
    }
}
