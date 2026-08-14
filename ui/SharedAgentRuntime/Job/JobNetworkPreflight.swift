import DBRepository
import EgressProxy
import Foundation
import MCPToolCatalog
import PolicyUserInteraction
import ServiceContracts

/// Before a scheduled job runs a network-enabled script, ensure hosts are allowlisted.
/// Uncovered hosts use the HITL **banner** path (not live chat modals / schedule preflight).
///
/// Helper push/grant goes through `InProcessServiceBridges` (installed by derrickd).
public enum JobNetworkPreflight {
    public enum PreflightError: Error, LocalizedError {
        case denied(host: String, actor: String?)
        case hardBlocked(host: String)

        public var errorDescription: String? {
            switch self {
            case .denied(let host, let actor):
                return "Network access to \(host) was not approved (\(actor ?? "user"))."
            case .hardBlocked(let host):
                return "Network access to \(host) is permanently blocked."
            }
        }
    }

    public static func approveScriptNetworkIfNeeded(
        toolName: String,
        argumentsJSON: String,
        jobID: String,
        repository: DBRepository
    ) async throws {
        guard AllowedMCPTool.isScriptExec(toolName) else { return }
        guard JobOrderPreflight.scriptAllowNetwork(toolArgumentsJSON: argumentsJSON) else { return }

        let script = JobOrderPreflight.scriptSource(from: argumentsJSON)
        let hosts = JobOrderPreflight.extractNetworkHosts(script: script)
        guard !hosts.isEmpty else { return }

        // Re-sync embedded helper from DB so settings removals take effect before this run.
        let suffixes = try await loadEnabledSuffixes(repository: repository)
        await InProcessServiceBridges.pushEgressAllowlist?(suffixes)

        let policy = DefaultDestinationPolicy(allowedDomainSuffixes: suffixes)
        var uncovered: [String] = []
        for host in hosts {
            if policy.isHardBlockedHostname(host) {
                throw PreflightError.hardBlocked(host: host)
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
                await InProcessServiceBridges.pushEgressAllowlist?(allowedSuffixes)
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
                throw PreflightError.denied(host: host, actor: actor)
            case .dismissed:
                throw PreflightError.denied(host: host, actor: "system-dismissed")
            case .timedOut:
                throw PreflightError.denied(host: host, actor: "system-timeout")
            }
        }

        if !sessionGrants.isEmpty {
            await InProcessServiceBridges.grantEgressSessionHosts?(sessionGrants)
        }
    }

    private static func loadEnabledSuffixes(repository: DBRepository) async throws -> [String] {
        let rows = try await repository.loadEgressAllowedDomainSuffixes(includeDisabled: false)
        return rows.filter(\.enabled).map(\.suffix)
    }
}
