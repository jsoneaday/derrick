import Foundation
import ServiceContracts

/// Invokes approved connector plugins for messaging operations.
public struct ConnectorPluginInvoker: Sendable {
    public typealias InvokeToolOutcome = @Sendable (String, Data) async throws -> String

    private let invokeToolOutcome: InvokeToolOutcome

    public init(invokeToolOutcome: @escaping InvokeToolOutcome) {
        self.invokeToolOutcome = invokeToolOutcome
    }

    public func invoke(
        pluginID: String,
        operation: ConnectorMessagingOperation,
        params: [String: PluginJSON] = [:]
    ) async throws -> ConnectorMessagingResult {
        let input = try ConnectorMessagingHopBuilder.inputData(operation: operation, params: params)
        let outcomeText = try await invokeToolOutcome(pluginID, input)
        return try ConnectorMessagingParser.parse(toolOutcomeText: outcomeText)
    }
}
