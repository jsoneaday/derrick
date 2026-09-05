import Foundation
import Plugin
import Structure

/// Host-owned dispatcher for capability hops emitted by Swift programs.
public enum PluginHostHopDispatcher: Sendable {
    /// Runs a compiled Swift artifact until it emits a terminal result,
    /// dispatching HTTP requests between invocations.
    public static func run(
        initialInput: Data,
        invokeID: String = UUID().uuidString,
        execute: @escaping @Sendable (Data) async throws -> PluginFactoryExecutionResult
    ) async throws -> PluginFactoryExecutionResult {
        var input = initialInput
        var lastResult = PluginFactoryExecutionResult(exitCode: 1)
        let params = (try? JSONDecoder().decode(PluginHopEvent.self, from: initialInput))?.params

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
            input = next
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
        let requests = envelopes.filter { $0.verb == .httpRequest }
        guard !requests.isEmpty else { return nil }

        var responses: [HostHTTPResponse] = []
        for request in requests {
            let requestID = request.payload["request_id"]?.stringValue ?? UUID().uuidString
            let live = await HostHTTPClient.shared.perform(
                method: request.payload["method"]?.stringValue ?? "GET",
                urlString: request.payload["url"]?.stringValue ?? "",
                invokeID: invokeID
            )
            responses.append(live.response(requestID: requestID))
        }

        return try? JSONEncoder().encode(
            PluginHopEvent(
                kind: .httpResults,
                httpResults: responses,
                params: params
            )
        )
    }
}
