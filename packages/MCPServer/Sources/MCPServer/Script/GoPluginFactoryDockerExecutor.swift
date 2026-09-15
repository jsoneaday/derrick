import Foundation
import Plugin
import Structure

/// Production adapter for the Go plugin factory.
public struct GoPluginFactoryDockerExecutor: PluginFactoryExecutor, PluginFactoryCompiledGuestExecutor, Sendable {
    private let runtime: GoGuestDockerExecutor

    public var image: String { runtime.image }

    public init(
        image: String = DockerWorkerRuntime.image,
        executor: @escaping DockerCLIExecutor
    ) {
        runtime = GoGuestDockerExecutor(image: image, executor: executor)
    }

    public func runGuestSource(
        source: String,
        input: Data
    ) async throws -> PluginFactoryExecutionResult {
        try await runtime.runSource(source: source, input: input)
    }

    public func runGuestSourceHops(
        source: String,
        testInput: Data
    ) async throws -> PluginFactoryHopTestRun {
        let script = try PluginFactoryTestScript.parse(testInput)
        return try await runtime.withCompiledGuest(source: source) { container in
            var hopResults: [PluginFactoryExecutionResult] = []
            var lastResult = PluginFactoryExecutionResult(exitCode: 1)

            for hop in script.hops {
                let input = try hop.encodeValidated()
                let result = try await runtime.runCompiledGuest(
                    container: container,
                    input: input
                )
                hopResults.append(result)
                lastResult = result
                guard result.exitCode == 0 else {
                    return PluginFactoryHopTestRun(final: result, hopResults: hopResults)
                }
            }

            return PluginFactoryHopTestRun(final: lastResult, hopResults: hopResults)
        }
    }

    public func packageGuestSource(source: String) async throws -> Data {
        try await runtime.compileSource(source)
    }

    public func runPackagedArtifact(
        _ artifact: Data,
        input: Data
    ) async throws -> PluginFactoryExecutionResult {
        try await runtime.runArtifact(artifact: artifact, input: input)
    }
}
