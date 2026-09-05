import Foundation
import MCPServer
import Structure

/// Attaches declared plugin Keychain secrets to host HTTP. Values never enter the guest.
public struct PluginDeclaredSecretAttacher: HostHTTPSecretAttacher {
    public init() {}

    public func apply(url: URL) async -> (url: URL, headers: [String: String]) {
        guard let pluginID = HostHTTPCallContext.shared.pluginID else {
            return (url, [:])
        }
        let fields = HostHTTPCallContext.shared.secretFields
        guard !fields.isEmpty else { return (url, [:]) }

        var values: [String: String] = [:]
        for field in fields {
            if let value = PluginSecretResolver.resolve(pluginID: pluginID, fieldID: field.id),
               !value.isEmpty {
                values[field.id] = value
            }
        }

        let username = fields.first(where: { $0.kind == "username" }).flatMap { values[$0.id] }
        let password = fields.first(where: { $0.kind == "password" }).flatMap { values[$0.id] }
        if let username, let password {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            return (url, ["Authorization": "Basic \(token)"])
        }

        let bearer = fields.first(where: { $0.kind == "token" || $0.kind == "api_key" }).flatMap { values[$0.id] }
        if let bearer {
            return (url, ["Authorization": "Bearer \(bearer)"])
        }

        return (url, [:])
    }
}
