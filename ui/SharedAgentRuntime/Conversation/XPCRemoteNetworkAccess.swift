import Foundation
import PolicyUserInteraction
import ServiceContracts

/// Reverse-XPC network host allow (preflight + mid-flight egress).
public enum XPCRemoteNetworkAccess {
    public static func prompt(
        host: String,
        toolName: String,
        resolveSink: @Sendable () -> AgentServiceClientSinkXPC?,
        timeoutSeconds: UInt64 = 300
    ) async -> PolicyUserDecision {
        let request = AgentNetworkAccessRequestDTO(host: host, toolName: toolName)
        guard let requestData = try? AgentServiceXPCCodec.encodeNetworkAccessRequest(request) else {
            debugLog("XPC network: encode failed host=\(host)")
            return .denied(actor: "system-encode-failed")
        }
        guard let sink = resolveSink() else {
            debugLog("XPC network: nil sink host=\(host)")
            return .denied(actor: "system-no-ui-sink")
        }

        debugLog("XPC network: requesting UI allow host=\(host) tool=\(toolName)")
        let sinkBox = UncheckedSinkBox(sink)
        let timeout = timeoutSeconds * 1_000_000_000

        do {
            let responseData: Data = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                        let replyBox = ReplyOnceBox(cont)
                        sinkBox.sink.requestNetworkAccess(requestJSON: requestData as NSData) { data in
                            replyBox.resume(returning: data as Data)
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeout)
                    throw NetworkTimeoutError()
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            let dto = try AgentServiceXPCCodec.decodeNetworkAccessDecision(responseData)
            let actor = dto.actor.isEmpty ? nil : dto.actor
            switch dto.decision.lowercased() {
            case "once":
                debugLog("XPC network: once host=\(host) actor=\(actor ?? "?")")
                return .approvedOnce(actor: actor)
            case "always":
                debugLog("XPC network: always host=\(host) actor=\(actor ?? "?")")
                return .approvedPermanently(actor: actor)
            case "allow", "approved":
                debugLog("XPC network: allow host=\(host) actor=\(actor ?? "?")")
                return .approved(actor: actor)
            case "timeout":
                return .timedOut
            case "dismissed":
                return .dismissed
            default:
                debugLog("XPC network: deny host=\(host) decision=\(dto.decision)")
                return .denied(actor: actor)
            }
        } catch is NetworkTimeoutError {
            debugLog("XPC network: timed out host=\(host)")
            return .timedOut
        } catch {
            debugLog("XPC network: failed host=\(host) error=\(error.localizedDescription)")
            return .denied(actor: "system-error")
        }
    }
}

private struct NetworkTimeoutError: Error {}

private final class UncheckedSinkBox: @unchecked Sendable {
    let sink: AgentServiceClientSinkXPC
    init(_ sink: AgentServiceClientSinkXPC) { self.sink = sink }
}

private final class ReplyOnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    init(_ continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func resume(returning data: Data) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: data)
    }
}
