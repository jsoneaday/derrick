import Foundation
import Plugin
import ServiceContracts

/// Production adapter for the Swift factory. The image is injected so releases
/// can pin a known Swift toolchain instead of silently following `latest`.
public struct SwiftPluginFactoryDockerExecutor: PluginFactoryExecutor, Sendable {
    private let runtime: SwiftDockerExecutor

    public var image: String { runtime.image }

    public init(
        image: String = DerrickGuestRuntime.swiftPluginDockerImage,
        executor: @escaping DockerCLIExecutor
    ) {
        runtime = SwiftDockerExecutor(image: image, executor: executor)
    }

    public func runSwiftFile(
        source: String,
        input: Data
    ) async throws -> PluginFactoryExecutionResult {
        try await runtime.runSource(source: source, input: input)
    }

    public func compileSwiftFile(source: String) async throws -> Data {
        try await runtime.compile(source: source)
    }

    public func runCompiledArtifact(
        _ artifact: Data,
        input: Data
    ) async throws -> PluginFactoryExecutionResult {
        try await runtime.runArtifact(artifact, input: input)
    }
}

public typealias SwiftPluginFactoryDockerError = SwiftDockerExecutorError
