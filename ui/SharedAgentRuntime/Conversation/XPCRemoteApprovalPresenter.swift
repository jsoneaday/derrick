import Foundation
import ServiceContracts

/// Asks the UI for tool approval over the AgentService reverse XPC sink (`requestApproval` + reply).
public final class XPCRemoteApprovalPresenter: ApprovalConfirmationPresenting, @unchecked Sendable {
    public typealias SinkResolver = @Sendable () -> AgentServiceClientSinkXPC?

    private let turnID: String
    private let resolveSink: SinkResolver
    private let timeoutNanoseconds: UInt64

    public init(
        turnID: String,
        timeoutSeconds: UInt64 = 300,
        resolveSink: @escaping SinkResolver
    ) {
        self.turnID = turnID
        self.timeoutNanoseconds = timeoutSeconds * 1_000_000_000
        self.resolveSink = resolveSink
    }

    public func confirm(_ request: ApprovalConfirmationRequest) async -> ApprovalConfirmationDecision {
        let dto = AgentApprovalRequestDTO(
            approvalID: request.id,
            turnID: turnID,
            sessionID: request.sessionID,
            toolName: request.toolName,
            argumentsJSON: request.argumentsJSON,
            requiredFields: request.requiredFields
        )

        guard let requestData = try? AgentServiceXPCCodec.encodeSignedApprovalRequest(dto) else {
            debugLog("XPC approval: failed to encode request id=\(request.id)")
            return .cancelled(actor: "system-encode-failed")
        }

        guard let sink = resolveSink() else {
            debugLog("XPC approval: nil sink for tool=\(request.toolName)")
            return .cancelled(actor: "system-no-ui-sink")
        }

        debugLog("XPC approval: requesting UI confirm tool=\(request.toolName) id=\(request.id)")

        let sinkBox = UncheckedSinkBox(sink)
        let requestBox = requestData
        let timeout = timeoutNanoseconds
        let originalArgs = request.argumentsJSON
        let toolName = request.toolName

        do {
            let responseData: Data = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                        let replyBox = ReplyOnceBox(cont)
                        sinkBox.sink.requestApproval(requestJSON: requestBox as NSData) { data in
                            replyBox.resume(returning: data as Data)
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeout)
                    throw ApprovalTimeoutError()
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }

            let decision = try AgentServiceXPCCodec.decodeSignedApprovalDecision(responseData)
            if decision.approved {
                let args = decision.editedArgumentsJSON.isEmpty
                    ? originalArgs
                    : decision.editedArgumentsJSON
                let actor = decision.actor.isEmpty ? nil : decision.actor
                debugLog("XPC approval: approved tool=\(toolName) actor=\(actor ?? "?")")
                return .approved(editedArgumentsJSON: args, actor: actor)
            }
            let actor = decision.actor.isEmpty ? "ui-user" : decision.actor
            debugLog("XPC approval: cancelled tool=\(toolName) actor=\(actor)")
            return .cancelled(actor: actor)
        } catch is ApprovalTimeoutError {
            debugLog("XPC approval: timed out tool=\(toolName)")
            return .cancelled(actor: "system-timeout")
        } catch {
            debugLog("XPC approval: failed tool=\(toolName) error=\(error.localizedDescription)")
            return .cancelled(actor: "system-error")
        }
    }
}

private struct ApprovalTimeoutError: Error {}

private final class UncheckedSinkBox: @unchecked Sendable {
    let sink: AgentServiceClientSinkXPC
    init(_ sink: AgentServiceClientSinkXPC) { self.sink = sink }
}

/// Ensures the XPC reply continuation is completed at most once.
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
