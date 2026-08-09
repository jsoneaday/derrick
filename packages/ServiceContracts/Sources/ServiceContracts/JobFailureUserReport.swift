import Foundation

/// Builds wake prompts so the agent can explain a failed scheduled job to the user.
public enum JobFailureUserReportPrompt: Sendable {
    public static func failureWakePrompt(
        originalWakePrompt: String,
        failureMessage: String,
        failureCode: String,
        silentOnSuccess: Bool = false
    ) -> String {
        let original = originalWakePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let failure = failureMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections: [String] = []
        if !original.isEmpty {
            sections.append(original)
        } else if silentOnSuccess {
            sections.append(
                """
                [job context]
                This job used wake_after=false (no notification on success). It failed unexpectedly, so you are being woken to notify the user.
                """
            )
        }
        sections.append(
            """
            [job failed]
            The scheduled background job did not complete successfully.
            Failure: \(failure.isEmpty ? "Unknown error" : failure)
            Internal code (do not mention to the user): \(failureCode)

            Your reply is shown alone in a small result modal after the user taps a notification.
            Write 2–4 short sentences of plain prose only:
            - State that the scheduled task failed and what it was trying to do.
            - Explain the cause in everyday language using the Failure line above.
            - You may suggest retry or a simple fix when obvious.

            Do NOT include: markdown tables, bullet lists of field names, code blocks, raw JSON, tracebacks, stack traces, internal codes (e.g. stepFailed), or "details were unavailable" when Failure has content.
            Do not invent success, partial results, or data that was not produced.
            Technical detail may be appended separately under "What went wrong" — do not duplicate it.
            """
        )
        return sections.joined(separator: "\n\n")
    }
}

/// Extracts agent wake metadata from job step payloads (for failure user reports).
public enum JobWakeContext: Sendable {
    public static func extractWakePayload(
        stepPayloadJSON: String,
        stepKind: JobStepKind,
        jobID: String
    ) -> JobWakeAgentPayload? {
        switch stepKind {
        case .wakeAgent:
            guard let wake = try? JSONDecoder.service.decode(
                JobWakeAgentPayload.self,
                from: Data(stepPayloadJSON.utf8)
            ) else { return nil }
            return normalized(wake, jobID: jobID)
        case .runToolThenWake:
            guard let combined = try? JSONDecoder.service.decode(
                JobRunToolThenWakePayload.self,
                from: Data(stepPayloadJSON.utf8)
            ) else { return nil }
            return normalized(combined.wake, jobID: jobID)
        case .runTool, .runToolBatch:
            return nil
        }
    }

    /// Prefer the failing step, then any step that carries wake metadata.
    public static func extractWakePayload(
        steps: [(kind: JobStepKind, payloadJSON: String)],
        failedStepPayloadJSON: String?,
        failedStepKind: JobStepKind?,
        jobID: String
    ) -> JobWakeAgentPayload? {
        if let failedStepPayloadJSON, let failedStepKind,
           let wake = extractWakePayload(
               stepPayloadJSON: failedStepPayloadJSON,
               stepKind: failedStepKind,
               jobID: jobID
           ) {
            return wake
        }
        for step in steps {
            if let wake = extractWakePayload(
                stepPayloadJSON: step.payloadJSON,
                stepKind: step.kind,
                jobID: jobID
            ) {
                return wake
            }
        }
        return nil
    }

    /// Wake metadata for failure reporting: explicit wake step, or synthesized for `runTool`-only jobs.
    public static func resolveFailureWakePayload(
        steps: [(kind: JobStepKind, payloadJSON: String)],
        failedStepPayloadJSON: String?,
        failedStepKind: JobStepKind?,
        jobID: String,
        principalJSON: String
    ) -> (wake: JobWakeAgentPayload, silentOnSuccess: Bool)? {
        if let wake = extractWakePayload(
            steps: steps,
            failedStepPayloadJSON: failedStepPayloadJSON,
            failedStepKind: failedStepKind,
            jobID: jobID
        ) {
            return (wake, false)
        }
        guard let synthesized = synthesizeFromToolOnlyJob(
            steps: steps,
            failedStepPayloadJSON: failedStepPayloadJSON,
            failedStepKind: failedStepKind,
            jobID: jobID,
            principalJSON: principalJSON
        ) else {
            return nil
        }
        return (synthesized, true)
    }

    private static func synthesizeFromToolOnlyJob(
        steps: [(kind: JobStepKind, payloadJSON: String)],
        failedStepPayloadJSON: String?,
        failedStepKind: JobStepKind?,
        jobID: String,
        principalJSON: String
    ) -> JobWakeAgentPayload? {
        let candidates: [(JobStepKind, String)] = {
            if let failedStepPayloadJSON, let failedStepKind {
                return [(failedStepKind, failedStepPayloadJSON)]
            }
            return steps.map { ($0.kind, $0.payloadJSON) }
        }()
        for (kind, payloadJSON) in candidates {
            guard kind == .runTool || kind == .runToolBatch else { continue }
            guard let tool = try? JSONDecoder.service.decode(
                JobRunToolPayload.self,
                from: Data(payloadJSON.utf8)
            ) else { continue }
            let modelJSON = tool.helperReviewerModelJSON.flatMap { Data($0.utf8) }
            return JobWakeAgentPayload(
                prompt: "",
                sessionID: JobSessionID.make(),
                agentID: JobSessionID.agentID,
                modelJSON: modelJSON,
                apiKey: tool.helperAPIKey,
                jobID: jobID,
                parentSessionID: parentSessionID(from: principalJSON)
            )
        }
        return nil
    }

    private static func parentSessionID(from principalJSON: String) -> String? {
        guard let principal = try? JSONDecoder.service.decode(
            ServicePrincipal.self,
            from: Data(principalJSON.utf8)
        ) else { return nil }
        if case .agent(let sessionID, _) = principal { return sessionID }
        return nil
    }

    private static func normalized(_ wake: JobWakeAgentPayload, jobID: String) -> JobWakeAgentPayload {
        JobWakeAgentPayload(
            prompt: wake.prompt,
            sessionID: wake.sessionID ?? JobSessionID.make(),
            agentID: wake.agentID ?? JobSessionID.agentID,
            modelJSON: wake.modelJSON,
            apiKey: wake.apiKey,
            jobID: wake.jobID ?? jobID,
            parentSessionID: wake.parentSessionID
        )
    }
}
