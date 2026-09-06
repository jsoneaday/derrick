import Foundation
import MCPServer
import Structure

public struct HarnessSecretAttacher: HostHTTPSecretAttacher {
    public let pluginID: String

    public init(pluginID: String) {
        self.pluginID = pluginID
    }

    public func apply(url: URL) async -> (url: URL, headers: [String: String]) {
        for fieldID in ["bot_token", "token", "api_key"] {
            if let token = PluginSecretResolver.resolve(pluginID: pluginID, fieldID: fieldID) {
                return (url, ["Authorization": "Bearer \(token)"])
            }
        }
        return (url, [:])
    }
}
