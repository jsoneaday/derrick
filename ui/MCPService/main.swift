import Foundation

let delegate = MCPServiceListenerDelegate()
let processInfo = ProcessInfo.processInfo
fputs("[MCPService] main starting pid=\(processInfo.processIdentifier)\n", stderr)
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
// Peer listener for AgentService (endpoint handed off via UI XPC, not disk).
_ = MCPServicePeerEndpoint.shared.endpointForHandoff()
fputs("[MCPService] listener resumed\n", stderr)
