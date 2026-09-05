import Foundation

/// In-process `plugin.invoke` for derrickd modules (ingress, jobs).
public enum PluginInvokeBridge: Sendable {
    public static func invoke(pluginID: String, input: Data) async throws -> String {
        guard let call = InProcessServiceBridges.mcpCallTool else {
            throw ConnectorMessagingBridgeError.invokeUnavailable
        }
        let argumentsJSON = try ConnectorMessagingBridgeEncoding.pluginInvokeArgumentsJSON(
            pluginID: pluginID,
            input: input
        )
        let request = MCPToolCallRequest(
            principal: .system,
            toolName: "plugin.invoke",
            argumentsJSON: argumentsJSON
        )
        let result = try await call(request)
        guard result.ok else {
            throw ConnectorMessagingBridgeError.invokeFailed(result.message.isEmpty ? result.text : result.message)
        }
        return result.text
    }
}

public enum ConnectorMessagingBridgeEncoding: Sendable {
    public static func pluginInvokeArgumentsJSON(pluginID: String, input: Data) throws -> String {
        guard let inputObject = try JSONSerialization.jsonObject(with: input) as? [String: Any] else {
            throw ConnectorMessagingBridgeError.invalidInput
        }
        _ = inputObject
        let payload: [String: Any] = [
            "plugin_id": pluginID,
            "input_json": String(decoding: input, as: UTF8.self) ?? "{}",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw ConnectorMessagingBridgeError.invalidInput
        }
        return json
    }
}

public enum ConnectorMessagingBridgeError: Error, LocalizedError, Equatable, Sendable {
    case invokeUnavailable
    case invokeFailed(String)
    case invalidInput

    public var errorDescription: String? {
        switch self {
        case .invokeUnavailable:
            return "plugin.invoke is not available in this process."
        case .invokeFailed(let detail):
            return detail
        case .invalidInput:
            return "Connector plugin input is invalid."
        }
    }
}
