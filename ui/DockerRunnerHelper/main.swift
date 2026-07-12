import Foundation

let delegate = DockerRunnerHelperDelegate()
let processInfo = ProcessInfo.processInfo
HelperLogRelay.shared.log("DockerRunnerHelper main starting. pid=\(processInfo.processIdentifier)")
HelperLogRelay.shared.log("Helper bundle path=\(Bundle.main.bundleURL.path)")
HelperLogRelay.shared.log("Helper executable path=\(processInfo.arguments.first ?? "<unknown>")")
let listener = NSXPCListener.service()
HelperLogRelay.shared.log("Created NSXPCListener.service().")
listener.delegate = delegate
HelperLogRelay.shared.log("Assigned listener delegate.")
listener.resume()
HelperLogRelay.shared.log("Listener resumed; helper is now waiting for XPC connections.")
