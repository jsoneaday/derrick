import Foundation
import MCPServer
import Structure

public struct HarnessSecretAttacher: HostHTTPSecretAttacher {
    public let pluginID: String

    public init(pluginID: String) {
        self.pluginID = pluginID
    }

    public func apply(url: URL) async -> (url: URL, headers: [String: String]) {
        if let token = PluginSecretResolver.resolveCallCredential(pluginID: pluginID) {
            return (url, ["Authorization": "Bearer \(token)"])
        }
        return (url, [:])
    }
}
