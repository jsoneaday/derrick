import Foundation
import DockerRunnerXPC
import os.log
import Structure

private let relayLogger = Logger(subsystem: "derrick.ui.DockerRunnerHelper", category: "relay")

final class HelperLogRelay: @unchecked Sendable {
    static let shared = HelperLogRelay()

    private let lock = NSLock()
    private var bufferedMessages: [String] = []
    private var sink: (any DockerHelperLogSinkXPC)?

    func log(_ message: String) {
        relayLogger.log("\(message, privacy: .public)")

        lock.lock()
        if let sink {
            lock.unlock()
            sink.appendLog(message: message)
            return
        }

        bufferedMessages.append(message)
        lock.unlock()
    }

    func attach(connection: NSXPCConnection) {
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            let nsError = error as NSError
            relayLogger.error("Failed to attach app log sink: domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public), description=\(nsError.localizedDescription, privacy: .public)")
        }

        guard let sink = proxy as? any DockerHelperLogSinkXPC else {
            log("App log sink unavailable; helper logs will remain local only.")
            return
        }

        let buffered: [String]
        lock.lock()
        self.sink = sink
        buffered = bufferedMessages
        bufferedMessages.removeAll()
        lock.unlock()

        if !buffered.isEmpty {
            sink.appendLog(message: "Helper log relay attached. Flushing \(buffered.count) buffered message(s).")
            for message in buffered {
                sink.appendLog(message: message)
            }
        } else {
            sink.appendLog(message: "Helper log relay attached.")
        }
    }

}
