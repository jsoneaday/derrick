import Foundation

/// Test / non-interactive HITL presenter that returns a fixed resolution.
public struct ImmediateGuardrailHITLPresenting: GuardrailHITLPresenting {
    private let resolution: GuardrailHITLResolution

    public init(approved: Bool) {
        self.resolution = approved
            ? .approved(editedPayloadJSON: nil, actor: nil)
            : .cancelled(actor: nil)
    }

    public init(resolution: GuardrailHITLResolution) {
        self.resolution = resolution
    }

    public func resolve(_ presentation: GuardrailHITLPresentation) async -> GuardrailHITLResolution {
        _ = presentation
        return resolution
    }
}

/// Bridges a closure to `GuardrailHITLPresenting`.
public struct ClosureGuardrailHITLPresenting: GuardrailHITLPresenting {
    private let handler: @Sendable (GuardrailHITLPresentation) async -> GuardrailHITLResolution

    public init(
        _ handler: @escaping @Sendable (GuardrailHITLPresentation) async -> GuardrailHITLResolution
    ) {
        self.handler = handler
    }

    public func resolve(_ presentation: GuardrailHITLPresentation) async -> GuardrailHITLResolution {
        await handler(presentation)
    }
}
