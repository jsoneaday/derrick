import Foundation
import Plugin
import Structure

/// Production adapter for the Python factory.
public struct PythonPluginFactoryDockerExecutor: PluginFactoryExecutor, Sendable {
    private let runtime: PythonGuestDockerExecutor

    public var image: String { runtime.image }

    public init(
        image: String = DerrickGuestRuntime.pythonGuestDockerImage,
        executor: @escaping DockerCLIExecutor
    ) {
        runtime = PythonGuestDockerExecutor(image: image, executor: executor)
    }

    public func runGuestSource(
        source: String,
        input: Data
    ) async throws -> PluginFactoryExecutionResult {
        try await runtime.runSource(source: source, input: input)
    }

    public func packageGuestSource(source: String) async throws -> Data {
        Data(source.utf8)
    }

    public func runPackagedArtifact(
        _ artifact: Data,
        input: Data
    ) async throws -> PluginFactoryExecutionResult {
        guard let source = String(data: artifact, encoding: .utf8) else {
            throw PythonGuestDockerExecutorError.commandFailed(
                "decode Python artifact",
                "artifact is not valid UTF-8"
            )
        }
        return try await runtime.runSource(source: source, input: input)
    }
}
