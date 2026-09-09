import DBRepository
import Foundation
import Structure

/// Routes newly persisted inbound connector messages to agent profiles when the bot is mentioned.
public enum MessagingAgentIngressRouter: Sendable {
    public static func processInbound(
        _ rows: [MessagingPersistResult],
        repository: DBRepository
    ) async {
        guard let routeHandler = InProcessServiceBridges.messagingAgentRoute else {
            fputs("[MessagingAgentIngressRouter] no route handler installed — inbound agent turns are skipped\n", stderr)
            return
        }

        for row in rows where row.message.direction == .inbound {
            guard let route = await routeCandidate(from: row, repository: repository) else {
                let body = row.message.body.trimmingCharacters(in: .whitespacesAndNewlines)
                if AgentProfileTokenParser.parse(message: body).handle != nil {
                    fputs(
                        "[MessagingAgentIngressRouter] skipped \(body.prefix(80)) pluginID=\(row.thread.pluginID)\n",
                        stderr
                    )
                }
                let parsedHandle = AgentProfileTokenParser.parse(message: body).handle
                if parsedHandle == nil,
                   let vendorMessageID = row.message.vendorMessageID?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !vendorMessageID.isEmpty {
                    _ = try? await repository.claimMessagingAgentHandling(
                        pluginID: row.thread.pluginID,
                        vendorMessageID: vendorMessageID
                    )
                }
                continue
            }
            do {
                let claimed = try await repository.claimMessagingAgentHandling(
                    pluginID: route.pluginID,
                    vendorMessageID: route.inboundVendorMessageID
                )
                guard claimed else { continue }
                fputs(
                    "[MessagingAgentIngressRouter] routing pluginID=\(route.pluginID) profile=\(route.profileHandle) message=\(route.inboundVendorMessageID)\n",
                    stderr
                )
                try await routeHandler(route)
            } catch {
                fputs(
                    "[MessagingAgentIngressRouter] route failed pluginID=\(route.pluginID) message=\(route.inboundVendorMessageID): \(error.localizedDescription)\n",
                    stderr
                )
                try? await repository.releaseMessagingAgentHandling(
                    pluginID: route.pluginID,
                    vendorMessageID: route.inboundVendorMessageID
                )
                await ServiceLogRecorder.shared.record(
                    service: "messaging",
                    level: .error,
                    code: "agent_route_failed",
                    message: "Messaging agent route failed pluginID=\(route.pluginID): \(error.localizedDescription)",
                    detailJSON: nil
                )
            }
        }
    }

    private static func routeCandidate(
        from row: MessagingPersistResult,
        repository: DBRepository
    ) async -> MessagingAgentRoute? {
        let message = row.message
        let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        guard !ConnectorMentionParser.isAutomatedOutboundEcho(body: body) else { return nil }

        let botUserID = await SlackBotIdentityResolver.Cache.shared
            .botUserID(pluginID: row.thread.pluginID)
            ?? ""
        if !botUserID.isEmpty,
           message.sender.trimmingCharacters(in: .whitespacesAndNewlines) == botUserID {
            return nil
        }

        guard let vendorMessageID = message.vendorMessageID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !vendorMessageID.isEmpty
        else {
            return nil
        }

        let threadParent = ConnectorMentionParser.agentReplyThreadParentVendorMessageID(
            inboundVendorMessageID: vendorMessageID,
            existingParentVendorMessageID: message.parentVendorMessageID
        )
        var continuation: String?
        if message.isReply {
            let threadMessages = (try? await repository.listMessagingMessages(
                threadID: row.thread.id,
                limit: MessagingViewport.maxVisibleMessages,
                filter: .replyThread(parentVendorMessageID: threadParent)
            )) ?? []
            continuation = ConnectorMentionParser.continuationProfileHandle(
                in: threadMessages,
                excludingVendorMessageID: vendorMessageID
            )
        }

        guard let resolved = ConnectorMentionParser.resolvePrompt(
            body: body,
            botUserID: botUserID,
            continuationProfileHandle: continuation,
            channelDefaultProfileHandle: row.thread.defaultAgentProfileHandle,
            profileCatalog: (try? await profileCatalog(repository: repository)) ?? []
        ) else {
            return nil
        }

        return MessagingAgentRoute(
            pluginID: row.thread.pluginID,
            threadID: row.thread.id,
            vendorThreadID: row.thread.vendorThreadID,
            parentVendorMessageID: threadParent,
            inboundVendorMessageID: vendorMessageID,
            profileHandle: resolved.profileHandle,
            prompt: resolved.prompt
        )
    }

    private static func profileCatalog(repository: DBRepository) async throws -> [AgentProfileCatalogEntry] {
        try await repository.listAgentProfiles()
            .filter(\.isEnabled)
            .map { AgentProfileCatalogEntry(handle: $0.handle, displayName: $0.displayName) }
    }
}
