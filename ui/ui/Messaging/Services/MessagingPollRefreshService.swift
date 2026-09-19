import Foundation
import Structure

/// Host service: wake daemon poll and refresh visible conversation from ingress.
@MainActor
enum MessagingPollRefreshService {
    static func requestPoll() {
        DerrickMessagingIngressSignal.postPoll()
    }

    static func refreshFromDaemon(
        session: MessagingSessionStore,
        catalog: MessagingCatalogStore,
        onAfterReload: () -> Void
    ) async {
        await session.reloadThreadsForSelectedConnector(autoOpenMostRecent: false)
        if let threadID = session.selectedThreadID {
            await session.reloadMessagesForThread(id: threadID)
        }
        await session.markVisibleConversationRead()
        await catalog.refreshBadges()
        onAfterReload()
    }
}
