import Foundation

/// Interprets a Policy rule set for one request kind into a `GuardrailDecision`.
public protocol GuardrailEvaluating<Request>: Sendable {
    associatedtype Request: Sendable
    func evaluate(_ request: Request) async throws -> GuardrailDecision
}
