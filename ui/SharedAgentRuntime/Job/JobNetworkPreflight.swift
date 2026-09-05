import DBRepository
import EgressProxy
import Foundation
import Plugin
import PolicyUserInteraction
import Structure

/// Before a scheduled network tool runs, ensure hosts are allowlisted.
/// Uncovered hosts use the HITL **banner** path (not live chat modals / schedule preflight).
///
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
            let decision = await HITLOfflineNetworkService.awaitDecision(
                host: host,
                toolName: toolName,
                turnID: "job-\(jobID)",
                isJobContext: true,
                repository: repository,
                timeoutNanoseconds: 300_000_000_000
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

        let suffixes = try await loadEnabledSuffixes(repository: repository)

        let policy = DefaultDestinationPolicy(allowedDomainSuffixes: suffixes)
        var uncovered: [String] = []
        for host in hosts {
            if policy.isHardBlockedHostname(host) {
                throw JobNetworkPreflightError.hardBlocked(host: host)
            }
            if policy.isHostCoveredByAllowlist(host) {
                continue
            }
            uncovered.append(host)
        }
        guard !uncovered.isEmpty else {
            fputs(
                "[JobNetworkPreflight] job=\(jobID) hosts covered count=\(hosts.count)\n",
                stderr
            )
            return
        }

        fputs(
            "[JobNetworkPreflight] job=\(jobID) banner approval needed hosts=\(uncovered.joined(separator: ","))\n",
            stderr
        )

        var sessionGrants: [String] = []
        var allowedSuffixes = suffixes
        for host in uncovered {
            let coverage = DefaultDestinationPolicy(allowedDomainSuffixes: allowedSuffixes)
            if coverage.isHostCoveredByAllowlist(host) {
                continue
            }
            // Session grants from earlier Allow Once in this preflight (suffix-scoped).
            let sessionPolicy = DefaultDestinationPolicy(allowedDomainSuffixes: [])
            sessionPolicy.grantSessionHosts(sessionGrants)
            if sessionPolicy.isHostCoveredByAllowlist(host) {
                continue
            }
            let decision = await HITLOfflineNetworkService.awaitDecision(
                host: host,
                toolName: toolName,
                turnID: "job-\(jobID)",
                isJobContext: true,
                repository: repository,
                timeoutNanoseconds: 300_000_000_000
            )
            switch decision {
            case .approvedPermanently(let actor):
                let suffix = EgressHostExtractor.permanentSuffix(for: host)
                try await repository.saveEgressAllowedDomainSuffix(
                    EgressAllowedDomainSuffix(suffix: suffix, source: actor ?? "job-banner", enabled: true)
                )
                allowedSuffixes = try await loadEnabledSuffixes(repository: repository)
                fputs(
                    "[JobNetworkPreflight] always host=\(host) suffix=\(suffix) actor=\(actor ?? "?")\n",
                    stderr
                )
            case .approved(let actor), .approvedOnce(let actor):
                sessionGrants.append(host)
                fputs(
                    "[JobNetworkPreflight] once host=\(host) actor=\(actor ?? "?")\n",
                    stderr
                )
            case .denied(let actor):
                throw JobNetworkPreflightError.denied(host: host, actor: actor)
            case .dismissed:
                throw JobNetworkPreflightError.denied(host: host, actor: "system-dismissed")
            case .timedOut:
                throw JobNetworkPreflightError.denied(host: host, actor: "system-timeout")
            }
        }

    }

    private static func loadEnabledSuffixes(repository: DBRepository) async throws -> [String] {
        let rows = try await repository.loadEgressAllowedDomainSuffixes(includeDisabled: false)
        return rows.filter(\.enabled).map(\.suffix)
    }
}
