import Foundation

let delegate = MCPServiceListenerDelegate()
let processInfo = ProcessInfo.processInfo
fputs("[MCPService] main starting pid=\(processInfo.processIdentifier)\n", stderr)
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
fputs("[MCPService] listener resumed\n", stderr)
