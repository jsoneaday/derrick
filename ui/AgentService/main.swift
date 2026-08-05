import Foundation

// Fan SharedAgentRuntime debugLog → stderr + service_logs + UI (when reverse XPC is up).
RuntimeLog.shared.addSink { message in
    if AgentServiceLogRelay.shouldRelayToUI(message) {
        AgentServiceLogRelay.shared.publish(message)
    }
    // Persist a slightly broader set to SQLite (still skip pure seed spam).
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
