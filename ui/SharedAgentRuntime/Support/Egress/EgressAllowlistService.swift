import Foundation
import Combine
import DBRepository
import DockerRunnerXPC
import EgressProxy
import AppEvents
import PolicyUserInteraction

/// App-owned egress allowlist: DB persistence + helper sync + preflight prompts.
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
            await pushToHelper()
        } catch {
            debugLog("Egress allowlist configure failed: \(error.localizedDescription)")
        }
    }

    func reload() async throws {
        guard let repository else {
            suffixes = []
            return
        }
        let rows = try await repository.loadEgressAllowedDomainSuffixes(includeDisabled: true)
        suffixes = rows
        localPolicy.setAllowedDomainSuffixes(rows.filter(\.enabled).map(\.suffix))
    }

    func enabledSuffixStrings() -> [String] {
        suffixes.filter(\.enabled).map(\.suffix)
    }

    func pushToHelper() async {
        // AgentService cannot open DockerRunnerHelper XPC; UI process owns helper sync.
        let bid = Bundle.main.bundleIdentifier ?? ""
        if bid == "derrick.ui.AgentService" || bid.hasSuffix(".AgentService") {
            return
        }
        await XPCDockerRunner.shared.pushEgressAllowedDomainSuffixes(enabledSuffixStrings())
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
        await pushToHelper()
    }

    func removeSuffix(id: String) async throws {
        guard let repository else { return }
        try await repository.deleteEgressAllowedDomainSuffix(id: id)
        try await reload()
        await pushToHelper()
    }

    /// Preflight network hosts before script execution.
    /// - Returns: nil if allowed to proceed; blocked tool-result JSON if user denied or hard-blocked.
    func preflightPythonScriptNetwork(
        script: String,
        allowNetwork: Bool,
        toolName: String = "python_script_exec"
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
        var promptedHosts = 0

        for host in hosts {
            if localPolicy.isHardBlockedHostname(host) {
                let message = "Network access to “\(host)” is permanently blocked (private/metadata host)."
                PipelineTiming.log(
                    "egress_preflight blocked_hard host=\(host) total_ms=\(PipelineTiming.elapsedMS(from: preflightStarted)) modal_ms=\(modalMS)"
                )
                // Modal published by pipeline from failureStage=egress result.
                return Self.blockedResultJSON(findings: [message], stage: "egress")
            }

            if localPolicy.isHostCoveredByAllowlist(host) {
                continue
            }

            promptedHosts += 1
            let modalStarted = Date()
            let decision = await promptForHost(host, toolName: toolName)
            modalMS += PipelineTiming.elapsedMS(from: modalStarted)
            switch decision {
            case .approved(let actor), .approvedOnce(let actor):
                debugLog("Egress allow once for \(host) by \(actor ?? "user")")
                sessionGrants.append(host)
                localPolicy.grantSessionHosts([host])
            case .approvedPermanently(let actor):
                debugLog("Egress allow always for \(host) by \(actor ?? "user")")
                let suffix = EgressHostExtractor.permanentSuffix(for: host)
                do {
                    try await addSuffix(suffix, source: "user")
                    // Session grant for exact host (mid-flight / www. vs apex) even if helper push fails.
                    sessionGrants.append(host)
                    localPolicy.grantSessionHosts([host])
                } catch {
                    debugLog("Failed to persist egress suffix \(suffix): \(error.localizedDescription)")
                    PipelineTiming.log(
                        "egress_preflight persist_failed host=\(host) total_ms=\(PipelineTiming.elapsedMS(from: preflightStarted)) modal_ms=\(modalMS)"
                    )
                    return Self.blockedResultJSON(
                        findings: ["Failed to save permanent allow for \(host): \(error.localizedDescription)"],
                        stage: "egress"
                    )
                }
            case .denied(let actor):
                debugLog("Egress deny for \(host) by \(actor ?? "user") — aborting entire script run")
                let message = "User denied network access to “\(host)”. The script was not run."
                PipelineTiming.log(
                    "egress_preflight user_denied host=\(host) total_ms=\(PipelineTiming.elapsedMS(from: preflightStarted)) modal_ms=\(modalMS) prompted_hosts=\(promptedHosts)"
                )
                return Self.blockedResultJSON(findings: [message], stage: "egress")
            case .dismissed, .timedOut:
                let message = "Network access to “\(host)” was not approved. The script was not run."
                PipelineTiming.log(
                    "egress_preflight dismissed_or_timeout host=\(host) total_ms=\(PipelineTiming.elapsedMS(from: preflightStarted)) modal_ms=\(modalMS)"
                )
                return Self.blockedResultJSON(findings: [message], stage: "egress")
            }
        }

        if !sessionGrants.isEmpty {
            await XPCDockerRunner.shared.grantEgressSessionHosts(sessionGrants)
        }
        PipelineTiming.log(
            "egress_preflight ok hosts=\(hosts.count) prompted=\(promptedHosts) session_grants=\(sessionGrants.count) total_ms=\(PipelineTiming.elapsedMS(from: preflightStarted)) modal_ms=\(modalMS)"
        )
        return nil
    }

    private func promptForHost(_ host: String, toolName: String) async -> PolicyUserDecision {
        // AgentService-hosted turns: reverse XPC to UI (process-wide / TaskLocal; no AppEventBus in XPC).
        if let remote = TurnProcessContext.effectiveNetworkAccessPrompt {
            debugLog("Egress prompt via reverse XPC host=\(host)")
            return await remote(host, toolName)
        }
        let event = PolicyUserEventFactory.egressAccessRequest(
            host: host,
            toolName: toolName
        )
        return await AppEventBus.shared.initDecision(event)
    }

    /// Apply a user egress decision in **this** process (UI): memory + helper allowlist.
    /// Call when the UI answers a reverse-XPC network prompt so mid-flight does not re-prompt.
    func applyUserNetworkDecision(host: String, decision: PolicyUserDecision) async {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }

        switch decision {
        case .approved(let actor), .approvedOnce(let actor):
            debugLog("Egress UI apply once host=\(normalized) actor=\(actor ?? "?")")
            localPolicy.grantSessionHosts([normalized])
            await XPCDockerRunner.shared.grantEgressSessionHosts([normalized])
        case .approvedPermanently(let actor):
            debugLog("Egress UI apply always host=\(normalized) actor=\(actor ?? "?")")
            let suffix = EgressHostExtractor.permanentSuffix(for: normalized)
            do {
                try await addSuffix(suffix, source: "user")
            } catch {
                debugLog("Egress UI apply always persist failed: \(error.localizedDescription)")
            }
            // Exact host + permanent suffix so helper/mid-flight skip immediately.
            localPolicy.grantSessionHosts([normalized])
            await XPCDockerRunner.shared.grantEgressSessionHosts([normalized])
            await pushToHelper()
        case .denied, .dismissed, .timedOut:
            break
        }
    }

    /// Mid-flight CONNECT hold from the helper (reverse XPC).
    /// Persists always-allow suffixes and session grants so the helper can complete the tunnel.
    func handleMidFlightHostAccess(host: String, toolName: String = "python_script_exec") async -> EgressHostAccessReply {
        let midStarted = Date()
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty {
            return EgressHostAccessReply(decision: .deny, actor: "system")
        }
        // AgentService may have persisted "always" to the shared DB; reload before prompting.
        if let repository {
            do {
                try await reload()
            } catch {
                debugLog("Egress mid-flight reload failed: \(error.localizedDescription)")
            }
        }
        if localPolicy.isHardBlockedHostname(normalized) {
            debugLog("Egress mid-flight hard-block for \(normalized)")
            PipelineTiming.log(
                "egress_midflight hard_block host=\(normalized) total_ms=\(PipelineTiming.elapsedMS(from: midStarted)) modal_ms=0"
            )
            return EgressHostAccessReply(decision: .deny, actor: "system")
        }
        // Already covered (preflight grant, permanent list, or shared DB).
        if localPolicy.isHostCoveredByAllowlist(normalized) {
            debugLog("Egress mid-flight already allowed for \(normalized)")
            // Keep helper session allowlist in sync for this CONNECT.
            await XPCDockerRunner.shared.grantEgressSessionHosts([normalized])
            PipelineTiming.log(
                "egress_midflight already_allowed host=\(normalized) total_ms=\(PipelineTiming.elapsedMS(from: midStarted)) modal_ms=0"
            )
            return EgressHostAccessReply(decision: .once, actor: "system")
        }

        let modalStarted = Date()
        let decision = await promptForHost(normalized, toolName: toolName)
        let modalMS = PipelineTiming.elapsedMS(from: modalStarted)
        switch decision {
        case .approved(let actor), .approvedOnce(let actor):
            debugLog("Egress mid-flight allow once for \(normalized) by \(actor ?? "user")")
            localPolicy.grantSessionHosts([normalized])
            await XPCDockerRunner.shared.grantEgressSessionHosts([normalized])
            PipelineTiming.log(
                "egress_midflight once host=\(normalized) total_ms=\(PipelineTiming.elapsedMS(from: midStarted)) modal_ms=\(modalMS)"
            )
            return EgressHostAccessReply(decision: .once, actor: actor)
        case .approvedPermanently(let actor):
            debugLog("Egress mid-flight allow always for \(normalized) by \(actor ?? "user")")
            let suffix = EgressHostExtractor.permanentSuffix(for: normalized)
            do {
                try await addSuffix(suffix, source: "user")
                // Session grant covers the exact host while permanent suffix propagates.
                localPolicy.grantSessionHosts([normalized])
                await XPCDockerRunner.shared.grantEgressSessionHosts([normalized])
                PipelineTiming.log(
                    "egress_midflight always host=\(normalized) total_ms=\(PipelineTiming.elapsedMS(from: midStarted)) modal_ms=\(modalMS)"
                )
                return EgressHostAccessReply(decision: .always, actor: actor)
            } catch {
                debugLog("Egress mid-flight permanent save failed: \(error.localizedDescription)")
                PipelineTiming.log(
                    "egress_midflight persist_failed host=\(normalized) total_ms=\(PipelineTiming.elapsedMS(from: midStarted)) modal_ms=\(modalMS)"
                )
                return EgressHostAccessReply(decision: .deny, actor: actor)
            }
        case .denied(let actor):
            debugLog("Egress mid-flight deny for \(normalized) by \(actor ?? "user")")
            PipelineTiming.log(
                "egress_midflight denied host=\(normalized) total_ms=\(PipelineTiming.elapsedMS(from: midStarted)) modal_ms=\(modalMS)"
            )
            return EgressHostAccessReply(decision: .deny, actor: actor)
        case .dismissed, .timedOut:
            debugLog("Egress mid-flight dismissed/timeout for \(normalized)")
            PipelineTiming.log(
                "egress_midflight dismissed_or_timeout host=\(normalized) total_ms=\(PipelineTiming.elapsedMS(from: midStarted)) modal_ms=\(modalMS)"
            )
            return EgressHostAccessReply(decision: .deny, actor: "system")
        }
    }

    private static func blockedResultJSON(findings: [String], stage: String) -> String {
        let payload: [String: Any] = [
            "status": "blocked",
            "decision": "deny",
            "failureStage": stage,
            "verifier": "egress-preflight",
            "validationFindings": findings,
            "reviewerAssessment": NSNull(),
            "stdout": "",
            "stderr": "",
            "exitCode": -1,
            "timedOut": false,
            "durationMS": 0
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"status":"blocked","decision":"deny","failureStage":"egress","validationFindings":["egress denied"]}"#
        }
        return text
    }
}
