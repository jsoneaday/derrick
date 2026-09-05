import Foundation
import Structure

/// Minimal in-process event bus with optional request/response for decisions.
public actor AppEventBus: AppEventBusing {
    public static let shared = AppEventBus()

    public typealias Handler = @Sendable (AnyAppEvent) async -> Void

    private var handlers: [UUID: Handler] = [:]
    private var decisionWaiters: [UUID: CheckedContinuation<any Sendable, Never>] = [:]

    public init() {}

    /// Subscribe to all published events. Returns an id for `unsubscribe`.
    @discardableResult
    public func subscribe(_ handler: @escaping Handler) -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id
    }

    public func unsubscribe(_ id: UUID) {
        handlers.removeValue(forKey: id)
    }

    /// Fire-and-forget publish to all subscribers.
    public func publish(_ event: any AppEvent) async {
        let boxed = AnyAppEvent(event)
        let snapshot = Array(handlers.values)
        for handler in snapshot {
            await handler(boxed)
        }
    }

    /// Publish a decision-requesting event and wait until `completeDecision` is called for its id.
    public func initDecision<E: DecisionRequestingEvent>(_ event: E) async -> E.Decision {
        let boxed = AnyAppEvent(event)
        let decision: any Sendable = await withCheckedContinuation { continuation in
            decisionWaiters[event.id] = continuation
            let snapshot = Array(handlers.values)
            Task {
                for handler in snapshot {
                    await handler(boxed)
                }
            }
        }
        guard let typed = decision as? E.Decision else {
            fatalError("AppEventBus: decision type mismatch for event \(event.id)")
        }
        return typed
    }

    /// Complete a pending `requestDecision` wait. Idempotent if already completed.
    public func completeDecision<D: Sendable>(id: UUID, decision: D) {
        guard let waiter = decisionWaiters.removeValue(forKey: id) else { return }
        waiter.resume(returning: decision)
    }

    /// Number of active decision waiters (tests / diagnostics).
    public var pendingDecisionCount: Int {
        decisionWaiters.count
    }

    /// Number of subscribers (tests / diagnostics).
    public var subscriberCount: Int {
        handlers.count
    }
}
