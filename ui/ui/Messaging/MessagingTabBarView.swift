import HostUI
import SwiftUI

/// Thin messaging wrapper around the shared HostUI tab strip.
struct MessagingTabBarView: View {
    @ObservedObject var store: MessagingStore

    var body: some View {
        HostUITabStrip(
            tabs: store.tabs.map {
                HostUITabItem(
                    id: $0.id,
                    title: $0.title,
                    unreadCount: $0.unreadCount,
                    muted: $0.muted
                )
            },
            selectedID: store.selectedThreadID,
            onSelect: { id in
                Task { await store.selectThread(id: id) }
            }
        )
    }
}
