import Foundation
import ServiceContracts

/// Multiplexes concurrent foreground turn streams by `turnID`.
final class TurnStreamHub: @unchecked Sendable {
    private struct Entry {
        let continuation: AsyncThrowingStream<AgentTurnChunkDTO, Error>.Continuation
        let finishGate: FinishGate
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func register(
        turnID: String,
        continuation: AsyncThrowingStream<AgentTurnChunkDTO, Error>.Continuation
    ) -> FinishGate {
        let gate = FinishGate()
        lock.lock()
        entries[turnID] = Entry(continuation: continuation, finishGate: gate)
        lock.unlock()
        return gate
    }

    func remove(turnID: String) {
        lock.lock()
        entries.removeValue(forKey: turnID)
        lock.unlock()
    }

    func deliverChunk(turnID: String, dto: AgentTurnChunkDTO) {
        lock.lock()
        let continuation = entries[turnID]?.continuation
        lock.unlock()
        continuation?.yield(dto)
    }

    func deliverFinish(turnID: String, errorDTO: AgentTurnErrorDTO?) {
        lock.lock()
        guard let entry = entries.removeValue(forKey: turnID) else {
            lock.unlock()
            return
        }
        let continuation = entry.continuation
        let gate = entry.finishGate
        lock.unlock()

        guard gate.markFinished() else { return }
        if let errorDTO {
            continuation.finish(throwing: AgentServiceClientError.turnFailed(errorDTO.message))
        } else {
            continuation.finish()
        }
    }
}

/// One-shot gate so stream finish is only applied once.
final class FinishGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    /// Returns true the first time; false if already finished.
    func markFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }
}
