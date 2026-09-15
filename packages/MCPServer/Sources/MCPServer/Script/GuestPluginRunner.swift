import Foundation
import Plugin
import Structure

/// Runs an approved factory release through the offline Go guest runtime.
public enum GuestPluginRunner: Sendable {
    public static func run(
        release: PluginFactoryRelease,
        input: Data,
        dockerExecutor: @escaping DockerCLIExecutor,
        timeoutSeconds: Int = GuestRuntimeLimits.effectiveScriptTimeoutSeconds(requested: 60),
        hopHandler: (any PluginHopHandler)? = nil,
        logger: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> PluginFactoryExecutionResult {
        let invokeID = UUID().uuidString
        let initialEvent = (try? PluginHopEvent.decodeValidated(input))
            ?? PluginHopEvent(kind: .manual)
        let executor = GoGuestDockerExecutor(executor: dockerExecutor)
        guard !release.compiledArtifact.isEmpty else {
            throw GoGuestDockerExecutorError.commandFailed(
                "load plugin artifact",
                "compiled artifact is empty"
            )
        }
        return try await GuestHopLoop.runForPluginInvoke(
            initialEvent: initialEvent,
            invokeID: invokeID,
            timeoutSeconds: timeoutSeconds,
            execute: { hopInput in
                try await executor.runArtifact(
                    artifact: release.compiledArtifact,
                    input: hopInput,
                    timeoutSeconds: timeoutSeconds
                )
            },
            logger: logger,
            hopHandler: hopHandler
        )
    }
}
