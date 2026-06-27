import Foundation

public struct ToolCallInterception<Input: Sendable, Output: Sendable>: Sendable {
    public let request: PolicyRequest
    public let payload: Input
    public let proceed: @Sendable (Input) async throws -> Output

    public init(
        request: PolicyRequest,
        payload: Input,
        proceed: @escaping @Sendable (Input) async throws -> Output
    ) {
        self.request = request
        self.payload = payload
        self.proceed = proceed
    }
}

public struct PolicyToolCallInterceptorAdapter<Presenter: PolicyConfirmationPresenting>: ToolCallInterceptor {
    public let interceptor: PolicyToolCallInterceptor<Presenter>

    public init(interceptor: PolicyToolCallInterceptor<Presenter>) {
        self.interceptor = interceptor
    }

    public func intercept<R: Sendable>(
        _ request: PolicyRequest,
        proceed: @escaping @Sendable () async throws -> R
    ) async throws -> R {
        try await interceptor.intercept(request, proceed: proceed)
    }

    public func intercept<Input: Sendable, Output: Sendable>(
        _ interception: ToolCallInterception<Input, Output>
    ) async throws -> Output {
        try await interceptor.intercept(interception.request) {
            try await interception.proceed(interception.payload)
        }
    }
}
