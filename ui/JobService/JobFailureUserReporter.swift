import DerrickBackend
import DBRepository
import Foundation
import ServiceContracts

/// On job failure: wake the agent with failure context → same notification/modal path as success.
enum JobFailureUserReporter {
    static func report(
        job: JobRow,
        steps: [JobStepRow],
        failedStep: JobStepRow?,
        reason: JobFailureReason,
        detail: String?
    ) async {
        let stepSummaries = steps.compactMap { row -> (kind: JobStepKind, payloadJSON: String)? in
            guard let kind = JobStepKind(rawValue: row.kind) else { return nil }
            return (kind: kind, payloadJSON: row.payloadJSON)
        }
        let failedKind = failedStep.flatMap { JobStepKind(rawValue: $0.kind) }
        guard let resolved = JobWakeContext.resolveFailureWakePayload(
            steps: stepSummaries,
            failedStepPayloadJSON: failedStep?.payloadJSON,
            failedStepKind: failedKind,
            jobID: job.id,
            principalJSON: job.principalJSON
        ) else {
            fputs("[JobService] job failed id=\(job.id) — no wake context; skip user notification\n", stderr)
            return
        }
        let wake = resolved.wake

        let failureMessage = reason.lastAttemptMessage(detail: detail)
        let prompt = JobFailureUserReportPrompt.failureWakePrompt(
            originalWakePrompt: wake.prompt,
            failureMessage: failureMessage,
            failureCode: reason.rawValue,
            silentOnSuccess: resolved.silentOnSuccess
        )
        let payload = JobWakeAgentPayload(
            prompt: prompt,
            sessionID: wake.sessionID,
            agentID: wake.agentID,
            modelJSON: wake.modelJSON,
            apiKey: wake.apiKey,
            jobID: job.id,
            parentSessionID: wake.parentSessionID
        )

        do {
            let accepted = try await JobAgentClient.shared.wakeAgent(payload: payload)
            guard accepted.ok else {
                throw JobServiceError.stepFailed(
                    accepted.message.isEmpty ? "Agent rejected failure report turn" : accepted.message
                )
            }
            fputs(
                "[JobService] failure user report wake accepted job=\(job.id) turn=\(accepted.turnID) silentOnSuccess=\(resolved.silentOnSuccess)\n",
                stderr
            )
        } catch {
            fputs(
                "[JobService] failure user report wake failed job=\(job.id): \(error.localizedDescription) — fallback notify\n",
                stderr
            )
            await persistFallback(
                wake: wake,
                jobID: job.id,
                responseText: failureMessage,
                failureCode: reason.rawValue
            )
        }
    }

    private static func persistFallback(
        wake: JobWakeAgentPayload,
        jobID: String,
        responseText: String,
        failureCode: String
    ) async {
            let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let repo = try await JobServiceStore.shared.sharedRepository()
            let detail = (try? await repo.fetchJobFailureMessage(id: jobID))
                .flatMap { JobFailureDisplay.technicalDetail(from: $0) }
            let composed = JobFailureDisplay.composePresentation(
                responseText: trimmed,
                failureDetail: detail,
                failureCode: failureCode
            )
            let result = JobResultDTO(
                jobID: jobID,
                jobSessionID: wake.sessionID ?? JobSessionID.make(),
                parentSessionID: wake.parentSessionID,
                responseText: composed
            )
            try await repo.insertJobResult(
                DBRepository.JobResultRow(
                    id: result.id,
                    jobID: result.jobID,
                    jobSessionID: result.jobSessionID,
                    parentSessionID: result.parentSessionID,
                    responseText: result.responseText,
                    createdAt: result.createdAt
                )
            )
            await JobResultNotifier.notifyCompletion(
                resultID: result.id,
                jobID: result.jobID,
                responseText: result.responseText,
                repository: repo
            )
            fputs("[JobService] failure fallback notified job=\(jobID) id=\(result.id)\n", stderr)
        } catch {
            fputs(
                "[JobService] failure fallback persist failed job=\(jobID): \(error.localizedDescription)\n",
                stderr
            )
        }
    }
}
