import DBRepository
import EgressProxy
import Foundation
import Plugin
import PolicyUserInteraction
import Structure

/// Before a scheduled network tool runs, prompt only on blacklist hits.
/// Public HTTPS is allowed by default; hard-blocked SSRF targets are denied without a prompt.
public enum JobNetworkPreflight {
    public static func approveScriptNetworkIfNeeded(
        toolName: String,
        argumentsJSON: String,
        jobID: String,
        repository: DBRepository
    ) async throws {
        let hosts: [String]
        if AllowedMCPTool.isScriptExec(toolName) {
            guard JobOrderPreflight.scriptAllowNetwork(toolArgumentsJSON: argumentsJSON) else { return }
            let script = JobOrderPreflight.scriptSource(from: argumentsJSON)
            hosts = JobOrderPreflight.extractNetworkHosts(script: script)
        } else if toolName == AllowedMCPTool.webCrawl.rawValue {
            guard let host = JobOrderPreflight.webCrawlStartHost(toolArgumentsJSON: argumentsJSON) else {
                return
            }
            hosts = [host]
        } else {
            return
        }
        guard !hosts.isEmpty else { return }

        let hardBlockPolicy = DefaultDestinationPolicy(allowedDomainSuffixes: [])
        for host in hosts {
            if hardBlockPolicy.isHardBlockedHostname(host) {
                throw JobNetworkPreflightError.hardBlocked(host: host)
            }
        }

        let blacklist = try await repository.listEgressBlacklist()
        let exceptions = try await repository.listEgressBlacklistExceptions()
        for host in hosts {
            guard case .prompt(let entry) = BlacklistHTTPPolicy.evaluate(
                host: host,
                blacklist: blacklist,
                exceptions: exceptions
            ) else {
                continue
            }
            let argumentsJSON = blacklistArgumentsJSON(host: host, entry: entry, toolName: toolName)
            let decision = await HITLOfflineNetworkService.awaitDecision(
                host: host,
                toolName: toolName,
                turnID: "job-\(jobID)",
                isJobContext: true,
                repository: repository,
                timeoutNanoseconds: 300_000_000_000,
                argumentsJSON: argumentsJSON
            )
            switch decision {
            case .approved, .approvedOnce:
                break
            case .approvedPermanently:
                try? await repository.deleteEgressBlacklistEntry(id: entry.id)
            case .denied(let actor):
                throw JobNetworkPreflightError.denied(host: host, actor: actor)
            case .dismissed:
                throw JobNetworkPreflightError.denied(host: host, actor: "system-dismissed")
            case .timedOut:
                throw JobNetworkPreflightError.denied(host: host, actor: "system-timeout")
            }
        }

        fputs(
            "[JobNetworkPreflight] job=\(jobID) ok hosts=\(hosts.count)\n",
            stderr
        )
    }

    private static func blacklistArgumentsJSON(
        host: String,
        entry: BlacklistEntry,
        toolName: String
    ) -> String {
        let payload: [String: String] = [
            "host": host,
            "url": "https://\(host)",
            "toolName": toolName,
            "kind": "blacklist",
            "pattern": entry.displayPattern,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"host":"\#(host)","toolName":"\#(toolName)","kind":"blacklist","pattern":"\#(entry.displayPattern)"}"#
        }
        return json
    }
}
