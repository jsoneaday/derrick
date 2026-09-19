import Combine
import Foundation
import Structure

/// Host service: session-lifetime inbound toast keys + present/clear.
@MainActor
final class MessagingInboundBannerService: ObservableObject {
    @Published private(set) var bannerText: String?
    @Published private(set) var bannerPluginID: String?
    @Published private(set) var bannerThreadID: String?

    private var presentedKeys: Set<String> = []
    private var primed = false
    private var dismissTask: Task<Void, Never>?

    func prime(visibleInbound: [MessagingMessageDTO]) {
        let current = Set(visibleInbound.map(MessagingInboundBannerDedupe.key(for:)))
        presentedKeys.formUnion(current)
        primed = true
    }

    /// Returns toast copy when a never-presented inbound key appears; otherwise nil.
    func presentIfNeeded(
        visibleInbound: [MessagingMessageDTO],
        isMessagingWorkspace: Bool,
        pluginID: String?
    ) -> (text: String, threadID: String)? {
        let current = Set(visibleInbound.map(MessagingInboundBannerDedupe.key(for:)))
        guard primed else {
            presentedKeys.formUnion(current)
            primed = true
            return nil
        }
        guard isMessagingWorkspace else { return nil }
        let fresh = MessagingInboundBannerDedupe.freshKeys(
            current: current,
            alreadyPresented: presentedKeys
        )
        guard !fresh.isEmpty else { return nil }
        let newest = visibleInbound.last {
            $0.direction == .inbound && fresh.contains(MessagingInboundBannerDedupe.key(for: $0))
        }
        presentedKeys.formUnion(fresh)
        guard let newest else { return nil }
        let sender = newest.sender.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = newest.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = body.count > 140 ? String(body.prefix(139)) + "…" : body
        let text: String
        if sender.isEmpty {
            text = preview
        } else if preview.isEmpty {
            text = sender
        } else {
            text = "\(sender): \(preview)"
        }
        show(text: text, pluginID: pluginID, threadID: newest.threadID)
        return (text, newest.threadID)
    }

    func show(text: String, pluginID: String?, threadID: String) {
        dismissTask?.cancel()
        bannerText = text
        bannerPluginID = pluginID
        bannerThreadID = threadID
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            clear()
        }
    }

    func clear() {
        dismissTask?.cancel()
        bannerText = nil
        bannerPluginID = nil
        bannerThreadID = nil
    }
}
