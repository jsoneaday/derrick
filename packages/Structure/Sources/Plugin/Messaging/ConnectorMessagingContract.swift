import Foundation

/// Host ↔ connector plugin contract for Messaging sync, poll, and send.
public enum ConnectorMessagingContract: Sendable {
    public static var hostContract: String {
        ConnectorContractPrompts.hostContract()
    }
}
