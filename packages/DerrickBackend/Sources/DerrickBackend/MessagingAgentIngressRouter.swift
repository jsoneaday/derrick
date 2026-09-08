import DBRepository
import Foundation
import Plugin
import Structure

/// Routes newly persisted inbound connector messages to agent profiles when the bot is mentioned.
public enum MessagingAgentIngressRouter: Sendable {
    public static func processInbound(
        _ rows: [MessagingPersistResult],
        repository: DBRepository
    ) async {
        guard let routeHandler = InProcessServiceBridges.messagingAgentRoute else {
            return
        }

        for row in rows where row.inserted && row.message.direction == .inbound {
            guard let route = await routeCandidate(from: row, repository: repository) else {
                continue
            }
            do {
                let claimed = try await repository.claimMessagingAgentHandling(
                    pluginID: route.pluginID,
                    vendorMessageID: route.inboundVendorMessageID
                )
                guard claimed else { continue }
                try await routeHandler(route)
            } catch {
                fputs(
                    "[MessagingAgentIngressRouter] route failed pluginID=\(route.pluginID) message=\(route.inboundVendorMessageID): \(error.localizedDescription)\n",
                    stderr
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

        let manifestJSON = (try? await repository.listLatestPluginFactoryManifests()
            .first(where: { $0.pluginID == row.thread.pluginID })?
            .manifestJSON) ?? ""
        guard supportsBotMentionRouting(manifestJSON: manifestJSON) else { return nil }

        guard let botUserID = await SlackBotIdentityResolver.Cache.shared
            .botUserID(pluginID: row.thread.pluginID)
        else {
            return nil
        }

        if message.sender.trimmingCharacters(in: .whitespacesAndNewlines) == botUserID {
            return nil
        }

        guard let resolved = ConnectorMentionParser.resolvePrompt(
            body: body,
            botUserID: botUserID,
            channelDefaultProfileHandle: row.thread.defaultAgentProfileHandle,
            profileCatalog: (try? await profileCatalog(repository: repository)) ?? []
        ) else {
            return nil
        }

        guard let vendorMessageID = message.vendorMessageID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !vendorMessageID.isEmpty
        else {
            return nil
        }

        return MessagingAgentRoute(
            pluginID: row.thread.pluginID,
            threadID: row.thread.id,
            vendorThreadID: row.thread.vendorThreadID,
            parentVendorMessageID: message.parentVendorMessageID,
            inboundVendorMessageID: vendorMessageID,
            profileHandle: resolved.profileHandle,
            prompt: resolved.prompt
        )
    }

    private static func supportsBotMentionRouting(manifestJSON: String) -> Bool {
        guard let data = manifestJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let extensions = object["extensions"] as? [String: Any],
              let derrick = extensions["app.derrick"] as? [String: Any]
        else {
            return false
        }
        let role = (derrick["role"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let authScheme = (derrick["auth_scheme"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return role == "connector" && authScheme == "bot_token"
    }

    private static func profileCatalog(repository: DBRepository) async throws -> [AgentProfileCatalogEntry] {
        try await repository.listAgentProfiles()
            .filter(\.isEnabled)
            .map { AgentProfileCatalogEntry(handle: $0.handle, displayName: $0.displayName) }
    }
}
