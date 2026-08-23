import Foundation
import ServiceContracts

/// Runs the prebuilt file extractor image with job-scoped `/data/in` and `/data/out` mounts.
public struct FileExtractorDockerExecutor: Sendable {
    public static let image = "derrick-file-extractor:swift-6.4-v1"
    public static let containerPrefix = "derrick-file-extractor"
    public static let maximumTimeoutSeconds = 180

    private let executor: DockerCLIExecutor

    public init(executor: @escaping DockerCLIExecutor) {
        self.executor = executor
    }

    public func run(
        input: Data,
        inputDirectory: URL,
        outputDirectory: URL,
        timeoutSeconds: Int
    ) async throws -> DockerCLIResult {
        let timeout = min(max(timeoutSeconds, 1), Self.maximumTimeoutSeconds)
        let imageCheck = try await executor(["image", "inspect", Self.image], Data(), 30)
        guard imageCheck.exitCode == 0 else {
            throw FileExtractorDockerExecutorError.imageUnavailable(Self.image)
        }
        let name = "\(Self.containerPrefix)-\(UUID().uuidString.lowercased())"
        let createArguments = Self.createArguments(
            name: name,
            inputDirectory: inputDirectory,
            outputDirectory: outputDirectory
        )
        do {
            let created = try await executor(createArguments, Data(), 60)
            guard created.exitCode == 0 else {
                throw FileExtractorDockerExecutorError.commandFailed(
                    "create file extractor container",
                    detail(from: created)
                )
            }
            let started = try await executor(["start", name], Data(), 30)
            guard started.exitCode == 0 else {
                throw FileExtractorDockerExecutorError.commandFailed(
                    "start file extractor container",
                    detail(from: started)
                )
            }
            let result = try await executor(
                ["exec", "-i", name, "/usr/local/bin/derrick-file-extractor"],
                input,
                timeout
            )
            await remove(name)
            return result
        } catch {
            await remove(name)
            throw error
        }
    }

    static func createArguments(
        name: String,
        inputDirectory: URL,
        outputDirectory: URL
    ) -> [String] {
        [
            "create",
            "--network", "none",
            "--read-only",
            "--tmpfs", "/tmp:rw,exec,nosuid,size=128m",
            "--pids-limit", "64",
            "--cpus", "1.0",
            "--memory", "512m",
            "-v", "\(inputDirectory.path):/data/in:ro",
            "-v", "\(outputDirectory.path):/data/out",
            "--name", name,
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

public enum FileExtractorDockerExecutorError: Error, LocalizedError, Sendable, Equatable {
    case commandFailed(String, String)
    case imageUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let step, let detail):
            return "\(step) failed: \(detail)"
        case .imageUnavailable(let image):
            return "File extractor image is not installed: \(image)."
        }
    }
}
