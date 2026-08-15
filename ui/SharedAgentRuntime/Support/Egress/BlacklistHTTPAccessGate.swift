import DBRepository
import Foundation
import Plugin
import PolicyUserInteraction
import ServiceContracts

/// Soft blacklist in front of host HTTP. Default allow. Prompt only on a hit.
public actor BlacklistHTTPAccessGate: HostHTTPAccessGate {
    private let repository: DBRepository
    private var thisRunKeys: [String: Set<String>] = [:]

    public init(repository: DBRepository) {
        self.repository = repository
    }

    public func authorize(url: URL, invokeID: String) async -> HostHTTPAccessDecision {
        guard let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
            return .deny("invalid_url")
        }
        let blacklist: [BlacklistEntry]
        let exceptions: [BlacklistEntry]
        do {
            blacklist = try await repository.listEgressBlacklist()
            exceptions = try await repository.listEgressBlacklistExceptions()
        } catch {
            return .deny("blacklist_store:\(error.localizedDescription)")
        }

        switch BlacklistHTTPPolicy.evaluate(host: host, blacklist: blacklist, exceptions: exceptions) {
        case .allow:
            return .allow
        case .prompt(let entry):
            let key = Self.entryKey(entry)
            if thisRunKeys[invokeID, default: []].contains(key) {
                return .allow
            }
            let decision = await prompt(url: url, entry: entry)
            switch decision {
            case .approved, .approvedOnce:
                thisRunKeys[invokeID, default: []].insert(key)
                return .allow
            case .approvedPermanently:
                try? await repository.deleteEgressBlacklistEntry(id: entry.id)
                thisRunKeys[invokeID, default: []].insert(key)
                return .allow
            case .denied, .dismissed, .timedOut:
                return .deny("blacklist:\(entry.displayPattern)")
            }
        }
    }

    private func prompt(url: URL, entry: BlacklistEntry) async -> PolicyUserDecision {
        let urlString = url.absoluteString
        let event = PolicyUserEventFactory.blacklistHitRequest(
            url: urlString,
            displayPattern: entry.displayPattern,
            kind: entry.kind.rawValue,
            pattern: entry.pattern
        )
        if currentJobID == nil, TurnProcessContext.effectivePolicyDecisionPrompt != nil {
            return await PolicyDecisionRouting.requestDecision(event)
        }
        let host = url.host ?? entry.pattern
        let jobID = currentJobID ?? "http"
        let payload: [String: String] = [
            "host": host,
            "url": urlString,
            "toolName": "script_exec",
            "kind": "blacklist",
            "pattern": entry.displayPattern,
        ]
        let args = (try? JSONSerialization.data(withJSONObject: payload)).flatMap {
            String(data: $0, encoding: .utf8)
        }
        return await HITLOfflineNetworkService.awaitDecision(
            host: host,
            toolName: "script_exec",
            turnID: "job-\(jobID)",
            isJobContext: true,
            repository: repository,
            timeoutNanoseconds: 300_000_000_000,
            argumentsJSON: args
        )
    }

    private var currentJobID: String? {
        HostHTTPCallContext.shared.jobID
    }

    private static func entryKey(_ entry: BlacklistEntry) -> String {
        "\(entry.kind.rawValue):\(entry.pattern)"
    }
}
