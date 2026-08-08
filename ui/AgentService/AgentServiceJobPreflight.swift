import DBRepository
import Foundation
import PolicyUserInteraction
import ServiceContracts

enum AgentServiceJobPreflight {
    enum PreflightError: Error, LocalizedError {
        case denied(actor: String)
        case noUISink
        case xpcFailed(String)

        var errorDescription: String? {
            switch self {
            case .denied(let actor):
                return "Job scheduling was not approved (\(actor))."
            case .noUISink:
                return "UI is not available to approve job scheduling."
            case .xpcFailed(let message):
                return "Job preflight failed: \(message)"
            }
        }
    }

    /// Returns after user approves (or immediately when no approval is required).
    static func approveBeforeSchedulingIfNeeded(
        toolName: String,
        toolArgumentsJSON: String
    ) async throws {
        let allowNetwork = JobOrderPreflight.pythonAllowNetwork(toolArgumentsJSON: toolArgumentsJSON)
        let script = JobOrderPreflight.pythonScript(from: toolArgumentsJSON)
        let uncovered = await MainActor.run {
            EgressAllowlistService.shared.uncoveredNetworkHosts(
                script: script,
                allowNetwork: allowNetwork
            )
        }
        guard let request = JobOrderPreflight.buildRequest(
            toolName: toolName,
            toolArgumentsJSON: toolArgumentsJSON,
            uncoveredNetworkHosts: uncovered
        ) else {
            fputs("[jobs_preflight] no approval required tool=\(toolName)\n", stderr)
            return
        }

        fputs("[jobs_preflight] requesting UI approval items=\(request.items.count)\n", stderr)
        let decision: JobPreflightDecisionDTO
        if let sink = AgentServicePrimaryUISink.shared.clientSink(logLabel: "job-preflight") {
            decision = try await requestViaUISink(request, sink: sink)
        } else {
            throw PreflightError.noUISink
        }

        guard decision.approved else {
            throw PreflightError.denied(actor: decision.actor)
        }

        let onceHosts = decision.grantNetworkOnce.isEmpty && !uncovered.isEmpty
            ? uncovered
            : decision.grantNetworkOnce
        for host in onceHosts {
            await EgressAllowlistService.shared.applyUserNetworkDecision(
                host: host,
                decision: .approvedOnce(actor: decision.actor)
            )
        }
        for host in decision.grantNetworkAlways {
            await EgressAllowlistService.shared.applyUserNetworkDecision(
                host: host,
                decision: .approvedPermanently(actor: decision.actor)
            )
        }
        fputs("[jobs_preflight] approved id=\(request.requestID)\n", stderr)
    }

    private static func requestViaUISink(
        _ request: JobPreflightRequestDTO,
        sink: AgentServiceClientSinkXPC
    ) async throws -> JobPreflightDecisionDTO {
        do {
            let payload = try AgentServiceXPCCodec.encodeSignedJobPreflightRequest(request)
            let replyData = await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
                sink.requestJobPreflight(requestJSON: payload as NSData) { reply in
                    continuation.resume(returning: reply as Data)
                }
            }
            return try AgentServiceXPCCodec.decodeSignedJobPreflightDecision(replyData)
        } catch {
            throw PreflightError.xpcFailed(error.localizedDescription)
        }
    }
}
