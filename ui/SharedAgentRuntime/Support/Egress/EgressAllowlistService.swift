import Foundation
import Combine
import DBRepository
import DockerRunnerXPC
import EgressProxy
import AppEvents
import PolicyUserInteraction
import ServiceContracts

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

    /// Concurrent CONNECT prompts coalesce into one modal (fixed window from first waiter).
    private var midFlightPending: [String: [CheckedContinuation<PolicyUserDecision, Never>]] = [:]
    private var midFlightFlushTask: Task<Void, Never>?
    private var midFlightPresenting = false
    private var midFlightToolName = "python_script_exec"
    private static let midFlightCoalesceNanoseconds: UInt64 = 500_000_000

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

    func enabledSuffixStrings() -> [String] {
        suffixes.filter(\.enabled).map(\.suffix)
    }

    /// UI embeds DockerRunnerHelper; AgentService cannot open that sibling XPC.
    private var isAgentServiceProcess: Bool {
        let bid = Bundle.main.bundleIdentifier ?? ""
        return bid == DerrickServiceID.agent.rawValue || bid.hasSuffix(".AgentService")
    }

    func pushToHelper() async {
        // AgentService cannot open DockerRunnerHelper XPC; UI process owns helper sync.
        if isAgentServiceProcess { return }
        await XPCDockerRunner.shared.pushEgressAllowedDomainSuffixes(enabledSuffixStrings())
    }

    /// Push session host grants to the helper only from the UI process.
    private func grantSessionHostsToHelper(_ hosts: [String]) async {
        guard !hosts.isEmpty else { return }
        if isAgentServiceProcess {
            debugLog(
                "Skipping helper session grant from AgentService (UI already applied via reverse XPC)"
            )
            return
        }
        await XPCDockerRunner.shared.grantEgressSessionHosts(hosts)
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
        try await reload(clearSessionHosts: true)
        await pushToHelper()
        // Daemon embedded helper resyncs from DB on the next JobNetworkPreflight.
        debugLog("Egress allowlist removed id=\(id) — UI helper synced; daemon resyncs on next job")
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
        var needsPrompt: [String] = []

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
                            findings: ["Failed to save permanent allow for \(host): \(error.localizedDescription)"],
                            stage: "egress"
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
                return Self.blockedResultJSON(findings: [message], stage: "egress")
            case .dismissed, .timedOut:
                let listed = needsPrompt.joined(separator: ", ")
                let message = "Network access to “\(listed)” was not approved. The script was not run."
                PipelineTiming.log(
                    "egress_preflight dismissed_or_timeout hosts=\(needsPrompt.count) total_ms=\(PipelineTiming.elapsedMS(from: preflightStarted)) modal_ms=\(modalMS)"
                )
                return Self.blockedResultJSON(findings: [message], stage: "egress")
            }
        }

        if !sessionGrants.isEmpty {
            await grantSessionHostsToHelper(sessionGrants)
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

    // MARK: - Mid-flight batching

    private func enqueueMidFlightHostPrompt(_ host: String, toolName: String) async -> PolicyUserDecision {
        midFlightToolName = toolName
        return await withCheckedContinuation { (continuation: CheckedContinuation<PolicyUserDecision, Never>) in
            midFlightPending[host, default: []].append(continuation)
            scheduleMidFlightFlushIfNeeded()
        }
    }

    private func scheduleMidFlightFlushIfNeeded() {
        guard midFlightFlushTask == nil, !midFlightPresenting else { return }
        midFlightFlushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.midFlightCoalesceNanoseconds)
            self.midFlightFlushTask = nil
            await self.flushMidFlightHostPrompts()
        }
    }

    private func flushMidFlightHostPrompts() async {
        guard !midFlightPending.isEmpty else { return }
        midFlightPresenting = true
        let snapshot = midFlightPending
        midFlightPending = [:]
        let hosts = Array(snapshot.keys).sorted()
        debugLog("Egress mid-flight batch prompt hosts=\(hosts.count)")
        let decision = await promptForHosts(hosts, toolName: midFlightToolName)
        for (_, waiters) in snapshot {
            for waiter in waiters {
                waiter.resume(returning: decision)
            }
        }
        midFlightPresenting = false
        if !midFlightPending.isEmpty {
            scheduleMidFlightFlushIfNeeded()
        }
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
            await grantSessionHostsToHelper([normalized])
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
            await grantSessionHostsToHelper([normalized])
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
        // Preserve session grants across reload (setAllowedDomainSuffixes does not clear them).
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
            await grantSessionHostsToHelper([normalized])
            PipelineTiming.log(
                "egress_midflight already_allowed host=\(normalized) total_ms=\(PipelineTiming.elapsedMS(from: midStarted)) modal_ms=0"
            )
            return EgressHostAccessReply(decision: .once, actor: "system")
        }

        let modalStarted = Date()
        let decision = await enqueueMidFlightHostPrompt(normalized, toolName: toolName)
        let modalMS = PipelineTiming.elapsedMS(from: modalStarted)
        switch decision {
        case .approved(let actor), .approvedOnce(let actor):
            debugLog("Egress mid-flight allow once for \(normalized) by \(actor ?? "user")")
            localPolicy.grantSessionHosts([normalized])
            await grantSessionHostsToHelper([normalized])
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
                await grantSessionHostsToHelper([normalized])
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
