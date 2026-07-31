import Foundation

/// HostAccessPrompter that calls out through a closure (wired to reverse XPC in the helper).
public struct ClosureHostAccessPrompter: HostAccessPrompter {
    private let handler: @Sendable (String) async -> HostAccessUserDecision

    public init(handler: @escaping @Sendable (String) async -> HostAccessUserDecision) {
        self.handler = handler
    }

    public func requestAccess(host: String) async -> HostAccessUserDecision {
        await handler(host)
    }
}
