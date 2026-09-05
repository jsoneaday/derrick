import Foundation
import Structure

public struct PolicyToolCallInterceptor<Presenter: PolicyConfirmationPresenting>: ToolCallInterceptor {
    public let engine: PolicyEngine
    public let presenter: Presenter

    public init(engine: PolicyEngine, presenter: Presenter) {
        self.engine = engine
        self.presenter = presenter
    }

    public func intercept<R: Sendable>(
        _ request: PolicyRequest,
        proceed: @escaping @Sendable () async throws -> R
    ) async throws -> R {
        switch engine.decision(for: request) {
        case .allow:
            return try await proceed()
        case .deny(let reason):
            throw PolicyError.denied(reason)
        case .confirm(let confirmation):
            if await presenter.confirm(confirmation) {
                return try await proceed()
            }
            throw PolicyError.cancelled
        }
    }
}
