import Foundation
import Plugin
import Structure

/// Runs an approved factory release through the offline Python guest runtime.
public enum GuestPluginRunner: Sendable {
    public static func run(
        release: PluginFactoryRelease,
        input: Data,
        dockerExecutor: @escaping DockerCLIExecutor,
        timeoutSeconds: Int = SwiftScriptPreparer.effectiveScriptTimeoutSeconds(requested: 60),
        hopHandler: (any PluginHopHandler)? = nil,
        logger: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> PluginFactoryExecutionResult {
        let invokeID = UUID().uuidString
        let initialEvent = (try? JSONDecoder().decode(PluginHopEvent.self, from: input))
            ?? PluginHopEvent(kind: .manual)
        let executor = PythonGuestDockerExecutor(executor: dockerExecutor)
        return try await GuestHopLoop.runForPluginInvoke(
            initialEvent: initialEvent,
            invokeID: invokeID,
            timeoutSeconds: timeoutSeconds,
            execute: { hopInput in
                try await executor.runSource(
                    source: release.guestSource,
                    input: hopInput,
                    timeoutSeconds: timeoutSeconds
                )
            },
            logger: logger,
            hopHandler: hopHandler
        )
    }
}
