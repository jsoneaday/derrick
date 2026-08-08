import Combine
import Foundation
import PolicyUserInteraction
import ServiceContracts
import SwiftUI

@MainActor
final class JobPreflightApprovalPresenter: ObservableObject {
    static let shared = JobPreflightApprovalPresenter()

    @Published private(set) var activeRequest: JobPreflightRequestDTO?
    @Published private(set) var isPresented = false

    private var continuation: CheckedContinuation<JobPreflightDecisionDTO, Never>?

    private init() {}

    func present(_ request: JobPreflightRequestDTO) async -> JobPreflightDecisionDTO {
        if let existing = activeRequest, isPresented {
            return JobPreflightDecisionDTO(
                requestID: existing.requestID,
                approved: false,
                actor: "ui-preflight-busy"
            )
        }
        activeRequest = request
        isPresented = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func approve(grantAlways: Bool = false) {
        guard let request = activeRequest else { return }
        let networkHosts = request.items.filter { $0.kind == "network" }.compactMap { networkHost(from: $0.detail) }
        let decision = JobPreflightDecisionDTO(
            requestID: request.requestID,
            approved: true,
            grantNetworkOnce: grantAlways ? [] : networkHosts,
            grantNetworkAlways: grantAlways ? networkHosts : [],
            actor: grantAlways ? "ui-preflight-always" : "ui-preflight-allow"
        )
        // Apply on the UI process before resuming AgentService: mid-flight CONNECT prompts
        // go to the UI↔helper reverse channel, not AgentService's in-memory allowlist.
        let hosts = networkHosts
        let always = grantAlways
        let actor = decision.actor
        Task { @MainActor in
            for host in hosts {
                await EgressAllowlistService.shared.applyUserNetworkDecision(
                    host: host,
                    decision: always
                        ? .approvedPermanently(actor: actor)
                        : .approvedOnce(actor: actor)
                )
            }
            if !hosts.isEmpty {
                debugLog(
                    "Job preflight applied \(always ? "always" : "once") grant(s) on UI/helper: \(hosts.joined(separator: ", "))"
                )
            }
            finish(decision)
        }
    }

    func deny() {
        guard let request = activeRequest else { return }
        finish(
            JobPreflightDecisionDTO(
                requestID: request.requestID,
                approved: false,
                actor: "ui-preflight-deny"
            )
        )
    }

    private func finish(_ decision: JobPreflightDecisionDTO) {
        isPresented = false
        activeRequest = nil
        continuation?.resume(returning: decision)
        continuation = nil
    }

    private func networkHost(from detail: String) -> String? {
        guard let range = detail.range(of: "reach ") else { return nil }
        return String(detail[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct JobPreflightModalView: View {
    let request: JobPreflightRequestDTO
    let onApprove: () -> Void
    let onApproveAlways: () -> Void
    let onDeny: () -> Void

    private var hasNetworkItems: Bool {
        request.items.contains { $0.kind == "network" }
    }

    private var networkHostsSummary: String {
        request.items
            .filter { $0.kind == "network" }
            .compactMap { item -> String? in
                guard let range = item.detail.range(of: "reach ") else { return nil }
                return String(item.detail[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Schedule this job?")
                .font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(request.items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.subheadline.weight(.semibold))
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(maxHeight: 220)

            HStack {
                Button("Cancel", role: .cancel, action: onDeny)
                Spacer()
                if hasNetworkItems {
                    Button("Always allow & Schedule", action: onApproveAlways)
                    Button("Allow & Schedule", action: onApprove)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Schedule", action: onApprove)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
    }

    private var subtitle: String {
        if hasNetworkItems {
            let hosts = networkHostsSummary.isEmpty ? "the listed hosts" : networkHostsSummary
            return "This both allows network access to \(hosts) and schedules the job. You’ll get a notification when it finishes."
        }
        return "Review what will run before it is scheduled. You’ll get a notification when it finishes."
    }
}

