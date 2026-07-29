import Foundation
import Combine
import DBRepository
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

        let hosts = EgressHostExtractor.extractHosts(from: script)
        guard !hosts.isEmpty else { return nil }

        var sessionGrants: [String] = []

        for host in hosts {
            if localPolicy.isHardBlockedHostname(host) {
                let message = "Network access to “\(host)” is permanently blocked (private/metadata host)."
                // Modal published by pipeline from failureStage=egress result.
                return Self.blockedResultJSON(findings: [message], stage: "egress")
            }

            if localPolicy.isHostCoveredByAllowlist(host) {
                continue
            }

            let decision = await promptForHost(host, toolName: toolName)
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
                } catch {
                    debugLog("Failed to persist egress suffix \(suffix): \(error.localizedDescription)")
                    return Self.blockedResultJSON(
                        findings: ["Failed to save permanent allow for \(host): \(error.localizedDescription)"],
                        stage: "egress"
                    )
                }
            case .denied(let actor):
                debugLog("Egress deny for \(host) by \(actor ?? "user") — aborting entire script run")
                let message = "User denied network access to “\(host)”. The script was not run."
                return Self.blockedResultJSON(findings: [message], stage: "egress")
            case .dismissed, .timedOut:
                let message = "Network access to “\(host)” was not approved. The script was not run."
                return Self.blockedResultJSON(findings: [message], stage: "egress")
            }
        }

        if !sessionGrants.isEmpty {
            await XPCDockerRunner.shared.grantEgressSessionHosts(sessionGrants)
        }
        return nil
    }

    private func promptForHost(_ host: String, toolName: String) async -> PolicyUserDecision {
        let event = PolicyUserEventFactory.egressAccessRequest(
            host: host,
            toolName: toolName
        )
        return await AppEventBus.shared.initDecision(event)
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
