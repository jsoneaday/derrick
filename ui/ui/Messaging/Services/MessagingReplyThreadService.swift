import Foundation
import Structure

/// Host service: open reply pane, poll thread replies, prime banners.
@MainActor
enum MessagingReplyThreadService {
    static func open(
        parentVendorMessageID: String,
        session: MessagingSessionStore,
        connectorRuntime: ConnectorMessagingRuntime,
        pluginID: String?,
        thread: MessagingThreadDTO?,
        primeInbound: @escaping () -> Void,
        publishPresence: () -> Void
    ) async {
        await session.openReplyThread(parentVendorMessageID: parentVendorMessageID)
        primeInbound()
        publishPresence()
        MessagingPollRefreshService.requestPoll()
        guard let pluginID, let thread else { return }
        // Paint from DB first; Slack poll catches peer replies without blocking the pane.
        Task {
            do {
                try await connectorRuntime.pollConversation(
                    pluginID: pluginID,
                    vendorThreadID: thread.vendorThreadID,
                    parentVendorMessageID: parentVendorMessageID,
                    threadID: thread.id,
                    session: session
                )
                session.setLastError(nil)
                primeInbound()
            } catch {
                let mapped = ConnectorReplyThreadAccessMessage.userFacing(
                    fromVendorDetail: error.localizedDescription
                ) ?? error.localizedDescription
                session.setReplyThreadWarning(mapped)
            }
        }
    }

    static func close(
        session: MessagingSessionStore,
        publishPresence: () -> Void
    ) {
        session.closeReplyThread()
        publishPresence()
        MessagingPollRefreshService.requestPoll()
    }
}
