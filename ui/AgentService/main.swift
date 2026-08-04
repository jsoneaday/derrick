import Foundation

// Fan SharedAgentRuntime debugLog into stderr + service_logs (skip high-volume noise).
RuntimeLog.shared.addSink { message in
    if message.contains("Memory DB migrations")
        || message.contains("Policy seed skipped")
        || message.contains("Egress allowlist seed skipped") {
        return
    }
    Task {
        await AgentServiceStore.shared.log(
            level: .debug,
            message: message,
            code: "runtime"
        )
    }
}

let delegate = AgentServiceListenerDelegate()
let processInfo = ProcessInfo.processInfo
fputs("[AgentService] main starting pid=\(processInfo.processIdentifier)\n", stderr)
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
fputs("[AgentService] listener resumed\n", stderr)
