import Foundation

/// In-process event bus for publishing app-wide events and awaiting user decisions.
public protocol AppEventBusing: Actor {
    typealias Handler = @Sendable (AnyAppEvent) async -> Void

    func subscribe(_ handler: @escaping Handler) -> UUID
    func unsubscribe(_ id: UUID)
    func publish(_ event: any AppEvent) async
    func initDecision<E: DecisionRequestingEvent>(_ event: E) async -> E.Decision
    func completeDecision<D: Sendable>(id: UUID, decision: D)
    var pendingDecisionCount: Int { get }
    var subscriberCount: Int { get }
}
