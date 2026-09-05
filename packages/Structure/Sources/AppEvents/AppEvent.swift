import Foundation

/// Shared priority for presentation and queue ordering.
public enum EventPriority: Int, Sendable, Comparable, Codable {
    case low = 0
    case normal = 10
    case high = 20
    /// Security / user decision — above ordinary notices.
    case userDecision = 30
    /// Startup / blocking environment.
    case critical = 40

    public static func < (lhs: EventPriority, rhs: EventPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Marker for all app-wide events.
public protocol AppEvent: Sendable {
    var id: UUID { get }
    var createdAt: Date { get }
    var priority: EventPriority { get }
    /// Loose correlation: turn, session, job run, heartbeat, etc.
    var correlationId: String? { get }
}

/// Events that need a user decision before a waiter can continue.
public protocol DecisionRequestingEvent: AppEvent {
    associatedtype Decision: Sendable
}

/// Type-erased box for bus storage.
public struct AnyAppEvent: Sendable {
    public let id: UUID
    public let createdAt: Date
    public let priority: EventPriority
    public let correlationId: String?
    public let base: any AppEvent

    public init(_ event: any AppEvent) {
        self.id = event.id
        self.createdAt = event.createdAt
        self.priority = event.priority
        self.correlationId = event.correlationId
        self.base = event
    }
}
