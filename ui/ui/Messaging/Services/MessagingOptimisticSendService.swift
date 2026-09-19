import Foundation
import Structure

/// Host service: show outbound immediately; cancel on failure; session merges on reload.
@MainActor
enum MessagingOptimisticSendService {
    @discardableResult
    static func begin(
        on session: MessagingSessionStore,
        body: String,
        parentVendorMessageID: String?
    ) -> String? {
        session.beginOptimisticOutbound(body: body, parentVendorMessageID: parentVendorMessageID)
    }

    static func cancel(on session: MessagingSessionStore, id: String) {
        session.cancelOptimisticOutbound(id: id)
    }
}
