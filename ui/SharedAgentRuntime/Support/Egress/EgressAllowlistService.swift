import Foundation
import Combine
import DBRepository
import EgressProxy
import AppEvents
import PolicyUserInteraction
import ServiceContracts

/// App-owned egress allowlist: DB persistence + host HTTP preflight prompts.
/// Not exposed as MCP. Not part of tool/content policy rules.
@MainActor
final class EgressAllowlistService: ObservableObject {
    static let shared = EgressAllowlistService()

    @Published private(set) var suffixes: [EgressAllowedDomainSuffix] = []

    private var repository: DBRepository?
    private let username = "ui"
    private let password = "ui"
    private let localPolicy = DefaultDestinationPolicy(allowedDomainSuffixes: [])

    private init() {}

    func configure(repository: DBRepository) async {
        self.repository = repository
        do {
            let inserted = try await repository.seedEgressAllowedDomainSuffixesIfNeeded(
                EgressProxyConfiguration.defaultSeedDomainSuffixes,
                source: "seed"
            )
            if inserted > 0 {
                debugLog("Egress allowlist seed inserted \(inserted) suffix(es).")
            } else {
                debugLog("Egress allowlist seed skipped (suffixes already present).")
            }
            try await reload()
        } catch {
            debugLog("Egress allowlist configure failed: \(error.localizedDescription)")
        }
    }

    func reload(clearSessionHosts: Bool = false) async throws {
        guard let repository else {
            suffixes = []
            return
        }
        let rows = try await repository.loadEgressAllowedDomainSuffixes(includeDisabled: true)
        suffixes = rows
        localPolicy.setAllowedDomainSuffixes(rows.filter(\.enabled).map(\.suffix))
        if clearSessionHosts {
            // Settings edits must not be shadowed by prior Allow-once / mid-flight grants.
            localPolicy.clearSessionHosts()
        }
    }

    private var isAgentServiceProcess: Bool {
        let bid = Bundle.main.bundleIdentifier ?? ""
        return bid == DerrickServiceID.agent.rawValue || bid.hasSuffix(".AgentService")
    }

    func addSuffix(_ raw: String, source: String = "user") async throws {
        let suffix = EgressHostExtractor.permanentSuffix(for: raw)
        guard EgressHostExtractor.isPlausibleHostname(suffix) || suffix.contains(".") else {
            throw NSError(
                domain: "EgressAllowlist",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid domain suffix: \(raw)"]
            )
        }
        guard let repository else { return }
        try await repository.saveEgressAllowedDomainSuffix(
            EgressAllowedDomainSuffix(suffix: suffix, source: source, enabled: true)
        )
        try await reload()
    }

    func removeSuffix(id: String) async throws {
        guard let repository else { return }
        try await repository.deleteEgressAllowedDomainSuffix(id: id)
        try await reload(clearSessionHosts: true)
        debugLog("Egress allowlist removed id=\(id)")
    }

    /// Preflight network hosts before script execution.
    /// - Returns: nil if allowed to proceed; blocked tool-result JSON if user denied or hard-blocked.
    func preflightScriptNetwork(
        script: String,
        allowNetwork: Bool,
        toolName: String = "script_exec"
    ) async -> String? {
        guard allowNetwork else { return nil }

        let preflightStarted = Date()
        let hosts = EgressHostExtractor.extractHosts(from: script)
        guard !hosts.isEmpty else {
            PipelineTiming.log("egress_preflight hosts=0 total_ms=0 modal_ms=0")
            return nil
        }

        var sessionGrants: [String] = []
        var modalMS = 0
        var needsPrompt: [String] = []

        for host in hosts {
            if localPolicy.isHardBlockedHostname(host) {
                let message = "Network access to “\(host)” is permanently blocked (private/metadata host)."
                PipelineTiming.log(
                    "egress_preflight blocked_hard host=\(host) total_ms=\(PipelineTiming.elapsedMS(from: preflightStarted)) modal_ms=\(modalMS)"
                )
                // Modal is published by the pipeline from the common network outcome.
                return Self.blockedResultJSON(findings: [message])
            }

            if localPolicy.isHostCoveredByAllowlist(host) {
                continue
            }
            needsPrompt.append(host)
        }

        if !needsPrompt.isEmpty {
            let modalStarted = Date()
            let decision = await promptForHosts(needsPrompt, toolName: toolName)
            modalMS += PipelineTiming.elapsedMS(from: modalStarted)
            switch decision {
            case .approved(let actor), .approvedOnce(let actor):
                debugLog("Egress allow once for \(needsPrompt.count) host(s) by \(actor ?? "user")")
                sessionGrants.append(contentsOf: needsPrompt)
                localPolicy.grantSessionHosts(needsPrompt)
            case .approvedPermanently(let actor):
                debugLog("Egress allow always for \(needsPrompt.count) host(s) by \(actor ?? "user")")
                for host in needsPrompt {
                    let suffix = EgressHostExtractor.permanentSuffix(for: host)
                    do {
                        try await addSuffix(suffix, source: "user")
                        sessionGrants.append(host)
                        localPolicy.grantSessionHosts([host])
                    } catch {
                        debugLog("Failed to persist egress suffix \(suffix): \(error.localizedDescription)")
                        PipelineTiming.log(
                            "egress_preflight persist_failed host=\(host) total_ms=\(PipelineTiming.elapsedMS(from: preflightStarted)) modal_ms=\(modalMS)"
                        )
                        return Self.blockedResultJSON(
                            findings: ["Failed to save permanent allow for \(host): \(error.localizedDescription)"]
                        )
                    }
                }
            case .denied(let actor):
                debugLog("Egress deny for \(needsPrompt.count) host(s) by \(actor ?? "user") — aborting entire script run")
                let listed = needsPrompt.joined(separator: ", ")
                let message = "User denied network access to “\(listed)”. The script was not run."
                PipelineTiming.log(
                    "egress_preflight user_denied hosts=\(needsPrompt.count) total_ms=\(PipelineTiming.elapsedMS(from: preflightStarted)) modal_ms=\(modalMS) prompted_hosts=\(needsPrompt.count)"
                )
                return Self.blockedResultJSON(findings: [message])
            case .dismissed, .timedOut:
                let listed = needsPrompt.joined(separator: ", ")
                let message = "Network access to “\(listed)” was not approved. The script was not run."
                PipelineTiming.log(
                    "egress_preflight dismissed_or_timeout hosts=\(needsPrompt.count) total_ms=\(PipelineTiming.elapsedMS(from: preflightStarted)) modal_ms=\(modalMS)"
                )
                return Self.blockedResultJSON(findings: [message])
            }
        }

        PipelineTiming.log(
            "egress_preflight ok hosts=\(hosts.count) prompted=\(needsPrompt.count) session_grants=\(sessionGrants.count) total_ms=\(PipelineTiming.elapsedMS(from: preflightStarted)) modal_ms=\(modalMS)"
        )
        return nil
    }

    private func promptForHosts(_ hosts: [String], toolName: String) async -> PolicyUserDecision {
        let unique = Self.uniqueHosts(hosts)
        guard !unique.isEmpty else {
            return .denied(actor: "system")
        }

        if let remote = TurnProcessContext.effectiveNetworkAccessPrompt {
            var last: PolicyUserDecision = .denied(actor: "system")
            for host in unique {
                debugLog("Egress prompt via AgentService path host=\(host)")
                last = await remote(host, toolName)
                switch last {
                case .denied, .dismissed, .timedOut:
                    return last
                case .approved, .approvedOnce, .approvedPermanently:
                    continue
                }
            }
            return last
        }

        if !isAgentServiceProcess {
            debugLog("Egress prompt via UI modal hosts=\(unique.count)")
            let event = PolicyUserEventFactory.egressAccessRequest(
                hosts: unique,
                toolName: toolName
            )
            return await AppEventBus.shared.initDecision(event)
        }

        guard let repository else {
            return .denied(actor: "system-no-repository")
        }
        var last: PolicyUserDecision = .denied(actor: "system")
        for host in unique {
            debugLog("Egress prompt via notification path host=\(host)")
            last = await HITLOfflineNetworkService.awaitDecision(
                host: host,
                toolName: toolName,
                turnID: "egress-agent",
                isJobContext: false,
                repository: repository,
                timeoutNanoseconds: 300_000_000_000
            )
            switch last {
            case .denied, .dismissed, .timedOut:
                return last
            case .approved, .approvedOnce, .approvedPermanently:
                continue
            }
        }
        return last
    }

    private static func uniqueHosts(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for raw in hosts {
            let host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !host.isEmpty, seen.insert(host).inserted else { continue }
            ordered.append(host)
        }
        return ordered
    }

    /// Apply a user egress decision in this process.
    /// Call when the UI answers a network prompt so later requests do not re-prompt.
    func applyUserNetworkDecision(host: String, decision: PolicyUserDecision) async {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }

        switch decision {
        case .approved(let actor), .approvedOnce(let actor):
            debugLog("Egress UI apply once host=\(normalized) actor=\(actor ?? "?")")
            localPolicy.grantSessionHosts([normalized])
        case .approvedPermanently(let actor):
            debugLog("Egress UI apply always host=\(normalized) actor=\(actor ?? "?")")
            let suffix = EgressHostExtractor.permanentSuffix(for: normalized)
            do {
                try await addSuffix(suffix, source: "user")
            } catch {
                debugLog("Egress UI apply always persist failed: \(error.localizedDescription)")
            }
            localPolicy.grantSessionHosts([normalized])
        case .denied, .dismissed, .timedOut:
            break
        }
    }

    private static func blockedResultJSON(findings: [String]) -> String {
        let diagnostics = findings.isEmpty
            ? [ToolExecutionOutcome.Diagnostic(code: "egress_denied", message: "Network access was denied.")]
            : findings.map {
                ToolExecutionOutcome.Diagnostic(code: "egress_denied", message: $0)
            }
        return (try? ToolExecutionOutcome.failure(
            status: .blocked,
            stage: .network,
            diagnostics: diagnostics,
            retry: ToolExecutionOutcome.Retry(allowed: false)
        ).encodedJSON()) ?? #"{"status":"blocked","stage":"network","diagnostics":[]}"#
    }
}
