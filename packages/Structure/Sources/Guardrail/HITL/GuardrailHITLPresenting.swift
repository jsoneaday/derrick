import Foundation

/// Context for presenting a Policy `confirmHITL` decision.
public struct GuardrailHITLPresentation: Sendable, Hashable {
    public let id: String
    public let sessionID: String
    public let turnID: String
    public let subject: String
    public let payloadJSON: String
    public let hitl: GuardrailHITLRequest
    public let isJobContext: Bool

    public init(
        id: String = UUID().uuidString,
        sessionID: String,
        turnID: String,
        subject: String,
        payloadJSON: String,
        hitl: GuardrailHITLRequest,
        isJobContext: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.turnID = turnID
        self.subject = subject
        self.payloadJSON = payloadJSON
        self.hitl = hitl
        self.isJobContext = isJobContext
    }
}

public enum GuardrailHITLResolution: Equatable, Sendable {
    case approved(editedPayloadJSON: String?, actor: String?)
    case cancelled(actor: String?)
}

/// Presents HITL and returns the human resolution. One implementation shared by all adapters.
public protocol GuardrailHITLPresenting: Sendable {
    func resolve(_ presentation: GuardrailHITLPresentation) async -> GuardrailHITLResolution
}
