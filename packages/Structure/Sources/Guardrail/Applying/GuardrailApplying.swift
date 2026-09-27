import Foundation

/// Applies a `GuardrailDecision` for one request kind.
public protocol GuardrailApplying<Request, Output>: Sendable {
    associatedtype Request: Sendable
    associatedtype Output: Sendable
    func apply(_ decision: GuardrailDecision, for request: Request) async throws -> Output
}
