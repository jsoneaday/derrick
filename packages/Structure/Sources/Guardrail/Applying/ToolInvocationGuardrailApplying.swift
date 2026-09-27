import Foundation

/// Applies a `GuardrailDecision` for tool invocations.
public struct ToolInvocationGuardrailApplying: GuardrailApplying {
    public typealias Request = ToolInvocationEvent
    public typealias Output = ToolInvocationEvent

    private let hitl: (any GuardrailHITLPresenting)?

    public init(hitl: (any GuardrailHITLPresenting)? = nil) {
        self.hitl = hitl
    }

    public func apply(
        _ decision: GuardrailDecision,
        for request: ToolInvocationEvent
    ) async throws -> ToolInvocationEvent {
        switch decision {
        case .allow:
            return request
        case .deny(let reason):
            throw ToolInvocationGuardrailError.denied(reason: reason)
        case .confirmHITL(let hitlRequest):
            guard let hitl else {
                throw ToolInvocationGuardrailError.denied(
                    reason: "Tool requires HITL approval but no presenter is configured."
                )
            }
            let presentation = GuardrailHITLPresentation(
                sessionID: request.sessionID,
                turnID: request.sessionID,
                subject: request.toolName,
                payloadJSON: request.argumentsJSON,
                hitl: hitlRequest
            )
            switch await hitl.resolve(presentation) {
            case .approved(let editedPayloadJSON, _):
                guard let editedPayloadJSON else { return request }
                return ToolInvocationEvent(
                    sessionID: request.sessionID,
                    toolName: request.toolName,
                    argumentsJSON: editedPayloadJSON,
                    timestamp: request.timestamp
                )
            case .cancelled(let actor):
                let suffix = actor.map { " by \($0)" } ?? ""
                throw ToolInvocationGuardrailError.cancelled(
                    reason: "User cancelled the approval request\(suffix)"
                )
            }
        case .redactArgument(let key, let pattern, let replacement):
            return ToolInvocationEvent(
                sessionID: request.sessionID,
                toolName: request.toolName,
                argumentsJSON: redactArgumentJSON(
                    request.argumentsJSON,
                    key: key,
                    pattern: pattern,
                    replacement: replacement
                ),
                timestamp: request.timestamp
            )
        case .requireWorkflow(let kind):
            throw ToolInvocationGuardrailError.denied(
                reason: "Tool requires workflow '\(kind.rawValue)' before it can run."
            )
        case .redactContent:
            throw ToolInvocationGuardrailError.denied(
                reason: "Tool policy returned an unsupported control decision."
            )
        }
    }
}

private func redactArgumentJSON(
    _ json: String,
    key: String,
    pattern: String,
    replacement: String
) -> String {
    guard let data = json.data(using: .utf8),
          var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return json
    }
    if let stringValue = object[key] as? String {
        object[key] = stringValue.replacingOccurrences(
            of: pattern,
            with: replacement,
            options: .regularExpression
        )
    }
    guard let redacted = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let redactedString = String(data: redacted, encoding: .utf8) else {
        return json
    }
    return redactedString
}
