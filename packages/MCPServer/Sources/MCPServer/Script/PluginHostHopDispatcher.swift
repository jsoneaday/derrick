import Foundation
import Plugin
import Structure

/// Host-owned dispatcher for capability hops emitted by guest programs.
public enum PluginHostHopDispatcher: Sendable {
    /// Runs a guest program until it emits a terminal result,
    /// dispatching HTTP requests between invocations.
    public static func run(
        initialInput: Data,
        invokeID: String = UUID().uuidString,
        execute: @escaping @Sendable (Data) async throws -> PluginFactoryExecutionResult
    ) async throws -> PluginFactoryExecutionResult {
        var input = initialInput
        var accumulated = (try? PluginHopEvent.decodeValidated(initialInput))
            ?? PluginHopEvent(kind: .manual)
        var lastResult = PluginFactoryExecutionResult(exitCode: 1)
        let params = accumulated.params

        for _ in 0..<PluginContract.maxHops {
            let result = try await execute(input)
            lastResult = result
            guard result.exitCode == 0 else { return result }
            let envelopes = try PluginEnvelopeList.decode(result.stdout)
            guard let next = await httpResultEvent(
                for: envelopes,
                invokeID: invokeID,
                params: params
            ) else {
                return result
            }
            let latest = try PluginHopEvent.decodeValidated(next)
            accumulated = accumulated.mergingLatestHTTPResults(latest)
            input = try accumulated.encodeValidated()
        }

        return PluginFactoryExecutionResult(
            exitCode: 1,
            stdout: lastResult.stdout,
            stderr: Data(
                "Plugin exceeded the \(PluginContract.maxHops)-hop HTTP limit.".utf8
            )
        )
    }

    /// Performs all HTTP requests in an envelope batch and returns the next
    /// JSON event. A nil result means the batch contains no HTTP requests.
    public static func httpResultEvent(
        for envelopes: [PluginEnvelope],
        invokeID: String,
        params: [String: PluginJSON]? = nil
    ) async -> Data? {
        let typedRequests: [HostHTTPRequest]
        do {
            typedRequests = try HostHTTPRequest.all(in: envelopes)
        } catch {
            return nil
        }
        guard !typedRequests.isEmpty else { return nil }

        var responses: [HostHTTPResponse] = []
        for request in typedRequests {
            let live = await HostHTTPClient.shared.perform(request, invokeID: invokeID)
            responses.append(live.response(requestID: request.requestID))
        }

        return try? PluginHopEvent(
            kind: .httpResults,
            httpResults: responses,
            params: params
        ).encodeValidated()
    }
}
