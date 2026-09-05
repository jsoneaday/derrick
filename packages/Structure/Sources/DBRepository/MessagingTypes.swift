import Foundation

public struct MessagingMessageInsertResult: Sendable, Hashable {
    public let inserted: Bool
    public let message: MessagingMessageDTO

    public init(inserted: Bool, message: MessagingMessageDTO) {
        self.inserted = inserted
        self.message = message
    }
}
