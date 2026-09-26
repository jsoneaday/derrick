import Foundation
import Plugin
import Structure

/// Production adapter for the Go plugin factory.
public struct GoPluginFactoryDockerExecutor: PluginFactoryExecutor, PluginFactoryCompiledGuestExecutor, PluginFactoryLiveAcceptanceExecutor, Sendable {
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

    public func runLiveAcceptance(
        artifact: Data,
        testInput: Data
    ) async throws -> PluginFactoryHopTestRun {
        let script = try PluginFactoryTestScript.parse(testInput)
        let liveHops = script.hops.filter { $0.kind != .httpResults && $0.httpResults?.isEmpty != false }
        if liveHops.isEmpty {
            let result = PluginFactoryExecutionResult(
                exitCode: 1,
                stderr: Data(
                    "Live acceptance needs a hop that is not a fixture http_results body.".utf8
                )
            )
            return PluginFactoryHopTestRun(final: result, hopResults: [result])
        }
        var hopResults: [PluginFactoryExecutionResult] = []
        var lastResult = PluginFactoryExecutionResult(exitCode: 1)
        var threadID: String?
        for hop in liveHops {
            let live = PluginLiveAcceptance.prepared(hop, discoveredThreadID: threadID)
            let input = try live.encodeValidated()
            let result = try await PluginHostHopDispatcher.run(initialInput: input) { hopInput in
                try await self.runtime.runArtifact(artifact: artifact, input: hopInput)
            }
            hopResults.append(result)
            lastResult = result
            if threadID == nil {
                threadID = PluginLiveAcceptance.firstThreadID(
                    in: String(decoding: result.stdout, as: UTF8.self)
                )
            }
            guard result.exitCode == 0 else { break }
        }
        return PluginFactoryHopTestRun(final: lastResult, hopResults: hopResults)
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
