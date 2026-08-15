import DBRepository
import EgressProxy
import Foundation
import Plugin
import PolicyUserInteraction

/// Ask before the model runs when the user prompt already names a blacklisted host.
public enum BlacklistPromptPreflight: Sendable {
    public enum Outcome: Sendable {
        case allowed
        case denied(String)
    }

    public static func approveUserPrompt(
        _ prompt: String,
        repository: DBRepository
    ) async -> Outcome {
        let hosts = EgressHostExtractor.extractHostsFromUserText(prompt)
        guard !hosts.isEmpty else { return .allowed }

        let blacklist: [BlacklistEntry]
        let exceptions: [BlacklistEntry]
        do {
            blacklist = try await repository.listEgressBlacklist()
            exceptions = try await repository.listEgressBlacklistExceptions()
        } catch {
            return .denied("Could not read the network blacklist: \(error.localizedDescription)")
        }
        guard !blacklist.isEmpty else { return .allowed }

        var seen = Set<String>()
        var hits: [BlacklistEntry] = []
        for host in hosts {
            switch BlacklistHTTPPolicy.evaluate(host: host, blacklist: blacklist, exceptions: exceptions) {
            case .prompt(let entry):
                let key = "\(entry.kind.rawValue):\(entry.pattern)"
                if seen.insert(key).inserted { hits.append(entry) }
            case .allow:
                break
            }
            for entry in blacklist where entry.kind == .suffix && entry.pattern == host {
                let key = "\(entry.kind.rawValue):\(entry.pattern)"
                if seen.insert(key).inserted { hits.append(entry) }
            }
        }

        for entry in hits {
            let url = displayURL(for: entry, hosts: hosts)
            let event = PolicyUserEventFactory.blacklistHitRequest(
                url: url,
                displayPattern: entry.displayPattern,
                kind: entry.kind.rawValue,
                pattern: entry.pattern
            )
            let decision = await PolicyDecisionRouting.requestDecision(event)
            switch decision {
            case .approved, .approvedOnce:
                continue
            case .approvedPermanently:
                try? await repository.deleteEgressBlacklistEntry(id: entry.id)
            case .denied, .dismissed, .timedOut:
                return .denied(
                    "“\(entry.displayPattern)” is on your network blacklist. The request was not sent to the model."
                )
            }
        }
        return .allowed
    }

    private static func displayURL(for entry: BlacklistEntry, hosts: [String]) -> String {
        if entry.kind == .exact {
            return "https://\(entry.pattern)"
        }
        if let host = hosts.first(where: { $0 == entry.pattern || $0.hasSuffix("." + entry.pattern) }) {
            return "https://\(host)"
        }
        return "https://\(entry.pattern)"
    }
}
