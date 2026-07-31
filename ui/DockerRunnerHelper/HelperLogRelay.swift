import Foundation
import DockerRunnerXPC
import EgressProxy
import os.log

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

    /// Reverse XPC: ask the app UI about mid-flight egress for `host`.
    func requestEgressHostAccess(host: String) async -> HostAccessUserDecision {
        let sink = currentSink()
        guard let sink else {
            log("Egress mid-flight prompt failed: no app sink for host=\(host)")
            return .deny
        }

        log("Egress mid-flight: requesting user decision for host=\(host)")

        return await withCheckedContinuation { (continuation: CheckedContinuation<HostAccessUserDecision, Never>) in
            let box = ResumeBox(continuation: continuation)
            sink.requestEgressHostAccess(host: host) { replyData in
                do {
                    let reply = try EgressHostAccessReply.decode(from: replyData as Data)
                    switch reply.decision {
                    case .once:
                        box.resume(.allowOnce)
                    case .always:
                        box.resume(.allowAlways)
                    case .deny:
                        box.resume(.deny)
                    }
                } catch {
                    HelperLogRelay.shared.log(
                        "Egress mid-flight: bad reply for host=\(host): \(error.localizedDescription)"
                    )
                    box.resume(.deny)
                }
            }
        }
    }

    private func currentSink() -> (any DockerHelperLogSinkXPC)? {
        lock.lock()
        defer { lock.unlock() }
        return sink
    }
}

/// Sendable once-resume helper for XPC reply callbacks.
private final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HostAccessUserDecision, Never>?

    init(continuation: CheckedContinuation<HostAccessUserDecision, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: HostAccessUserDecision) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: value)
    }
}
