import Foundation
import Structure

public struct DefaultToolRequestInterceptor: ToolRequestInterceptor {
    private let policy: ToolGovernancePolicy?

    public init(policy: ToolGovernancePolicy? = nil) {
        self.policy = policy
    }

    public func evaluateToolInvocation(_ event: ToolInvocationEvent) async throws -> ToolInterceptionDecision {
        guard let policy else {
            return .allow(event)
        }

        let outcome = try await policy.evaluateToolInvocation(event)
        switch outcome {
        case .allow:
            return .allow(event)
        case .deny(let reason):
            return .deny(reason: reason)
        case .confirm(let requiredFields):
            return .confirm(event, requiredFields: requiredFields)
        case .redact(let key, let pattern, let replacement):
            guard let parsedArgs = try? JSONSerialization.jsonObject(with: event.argumentsJSON.data(using: .utf8) ?? Data(), options: []) as? [String: Any] else {
                return .allow(event)
            }

            var mutableArgs = parsedArgs
            if let stringValue = mutableArgs[key] as? String {
                mutableArgs[key] = stringValue.replacingOccurrences(
                    of: pattern,
                    with: replacement,
                    options: .regularExpression
                )
            }

            guard let redactedJSON = try? JSONSerialization.data(withJSONObject: mutableArgs, options: [.sortedKeys]),
                  let redactedString = String(data: redactedJSON, encoding: .utf8) else {
                return .allow(event)
            }

            return .allow(
                ToolInvocationEvent(
                    sessionID: event.sessionID,
                    toolName: event.toolName,
                    argumentsJSON: redactedString,
                    timestamp: event.timestamp
                )
            )
        }
    }

    public func interceptToolInvocation(_ event: ToolInvocationEvent) async throws -> ToolInvocationEvent? {
        switch try await evaluateToolInvocation(event) {
        case .allow(let processedEvent):
            return processedEvent
        case .deny:
            return nil
        case .confirm(let processedEvent, _):
            return processedEvent
        }
    }

    public func interceptAndRun<R: Sendable>(
        _ event: ToolInvocationEvent,
        confirm: nonisolated(nonsending) @escaping @Sendable (ToolInvocationEvent, [String]) async throws -> ToolInvocationConfirmation,
        proceed: nonisolated(nonsending) @escaping @Sendable (ToolInvocationEvent) async throws -> R
    ) async throws -> R {
        switch try await evaluateToolInvocation(event) {
        case .allow(let allowedEvent):
            return try await proceed(allowedEvent)
        case .deny(let reason):
            throw ToolInvocationInterceptionError.denied(reason: reason)
        case .confirm(let confirmEvent, let requiredFields):
            switch try await confirm(confirmEvent, requiredFields) {
            case .approved(let approvedEvent):
                return try await proceed(approvedEvent)
            case .cancelled(let actor):
                let suffix = actor.map { " by \($0)" } ?? ""
                throw ToolInvocationInterceptionError.cancelled(
                    reason: "User cancelled the approval request\(suffix)"
                )
            }
        }
    }
}
