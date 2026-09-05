import Foundation
import Structure

import Foundation
import Structure

/// Simple FIFO mailbox. Actor-isolated; not shared across processes.
public actor InMemoryMailbox: AgentMailboxing {
    private var queue: [AgentEnvelope] = []
    private let limit: Int
    private let ref: AgentRef

    public init(ref: AgentRef, limit: Int = OrchestrationLimits.recommended.maxMailboxDepth) {
        self.ref = ref
        self.limit = limit
    }

    public func enqueue(_ envelope: AgentEnvelope) async throws {
        guard queue.count < limit else {
            throw AgentRuntimeError.mailboxFull(ref, limit: limit)
        }
        queue.append(envelope)
    }

    public func dequeue() async -> AgentEnvelope? {
        guard !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }

    public func peekCount() async -> Int {
        queue.count
    }
}
