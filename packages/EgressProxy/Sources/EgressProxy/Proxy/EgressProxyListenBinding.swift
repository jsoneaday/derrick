import Foundation
import Network
import Structure

/// Builds TCP listener parameters that bind only to a specific host (default loopback).
public enum EgressProxyListenBinding: Sendable {
    /// - Parameters:
    ///   - host: Address to bind (e.g. `127.0.0.1`).
    ///   - port: TCP port.
    public static func tcpParameters(host: String, port: UInt16) -> NWParameters {
        let nwPort = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: 18_080)!
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: nwPort
        )
        return parameters
    }
}
