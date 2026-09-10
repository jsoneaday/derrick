import Foundation
import Structure

/// Runs the prebuilt file extractor in a oneshot container: create, exec, rm.
/// Own queue (max 1). Job folders are bind-mounted; the image must already
/// exist (`docker image inspect` happens outside the permit).
public struct FileExtractorDockerExecutor: Sendable {
    public static let image = DockerWorkerRuntime.image
    public static let containerPrefix = "derrick-file-extractor"
    public static let binaryPath = DockerWorkerRuntime.extractorBinary
    public static let maximumTimeoutSeconds = 180

    private let executor: DockerCLIExecutor
    private let queue: DerrickDockerRunQueue

    public init(
        executor: @escaping DockerCLIExecutor,
        queue: DerrickDockerRunQueue = .extractor
    ) {
        self.executor = executor
        self.queue = queue
    }

    public func run(
        input: Data,
        inputDirectory: URL,
        outputDirectory: URL,
        timeoutSeconds: Int
    ) async throws -> DockerCLIResult {
        let timeout = min(max(timeoutSeconds, 1), Self.maximumTimeoutSeconds)
        try await WorkerImageGate.shared.ensureReady(executor: executor)
        let executor = self.executor
        do {
            return try await queue.withPermit {
                try await OneshotDockerContainer.run(
                    executor: executor,
                    prefix: Self.containerPrefix,
                    createArguments: { name in
                        Self.createArguments(
                            name: name,
                            inputDirectory: inputDirectory,
                            outputDirectory: outputDirectory
                        )
                    },
                    createStep: "create file extractor container",
                    startStep: "start file extractor container",
                    body: { name in
                        try await executor(
                            ["exec", "-i", name, Self.binaryPath],
                            input,
                            timeout
                        )
                    }
                )
            }
        } catch let error as OneshotDockerContainerError {
            throw mappedExtractorError(error)
        }
    }

    static func createArguments(
        name: String,
        inputDirectory: URL,
        outputDirectory: URL
    ) -> [String] {
        [
            "create",
        ] + DerrickDockerRuntimeIdentity.createLabelArguments + [
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

    private func mappedExtractorError(_ error: OneshotDockerContainerError) -> Error {
        switch error {
        case .commandFailed(let step, let detail):
            return FileExtractorDockerExecutorError.commandFailed(step, detail)
        case .imageUnavailable(let detail):
            return FileExtractorDockerExecutorError.imageUnavailable(detail)
        }
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
