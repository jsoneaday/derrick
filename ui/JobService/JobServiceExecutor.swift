import Foundation
import DBRepository
import ServiceContracts

/// Runs claimed job steps. Tool execution uses peer-mesh MCP XPC callTool (signed).
actor JobServiceExecutor {
    static let shared = JobServiceExecutor()

    func execute(job: JobRow, steps: [JobStepRow]) async {
        // Prevent idle system sleep only while this job runs (released on all exit paths).
        let sleepToken = JobServiceSleepAssertion.shared.begin(jobID: job.id)
        defer { sleepToken.end() }

        let repo: DBRepository
        do {
            repo = try await JobServiceStore.shared.sharedRepository()
        } catch {
            fputs("[JobService] executor no repo: \(error.localizedDescription)\n", stderr)
            return
        }

        var ordered = steps.sorted { $0.index < $1.index }
        for index in ordered.indices {
            var step = ordered[index]
            if step.status == JobStepStatus.succeeded.rawValue
                || step.status == JobStepStatus.skipped.rawValue
            {
                continue
            }
            guard let kind = JobStepKind(rawValue: step.kind) else {
                await failJob(
                    repo: repo,
                    job: job,
                    steps: ordered,
                    failedStep: step,
                    reason: .invalidRecord,
                    detail: "unknown step kind \(step.kind)"
                )
                return
            }

            step.status = JobStepStatus.running.rawValue
            step.startedAt = Date()
            try? await repo.updateStep(step)

            do {
                switch kind {
                case .runTool:
                    let result = try await runToolStep(payloadJSON: step.payloadJSON, principalJSON: job.principalJSON)
                    step.status = JobStepStatus.succeeded.rawValue
                    step.resultJSON = result
                    step.finishedAt = Date()
                    try await repo.updateStep(step)
                case .runToolBatch:
                    let result = try await runToolBatchStep(payloadJSON: step.payloadJSON, principalJSON: job.principalJSON)
                    step.status = JobStepStatus.succeeded.rawValue
                    step.resultJSON = result
                    step.finishedAt = Date()
                    try await repo.updateStep(step)
                case .wakeAgent:
                    let result = try await wakeAgentStep(payloadJSON: step.payloadJSON)
                    step.status = JobStepStatus.succeeded.rawValue
                    step.resultJSON = result
                    step.finishedAt = Date()
                    try await repo.updateStep(step)
                case .runToolThenWake:
                    let result = try await runToolThenWakeStep(
                        payloadJSON: step.payloadJSON,
                        principalJSON: job.principalJSON
                    )
                    step.status = JobStepStatus.succeeded.rawValue
                    step.resultJSON = result
                    step.finishedAt = Date()
                    try await repo.updateStep(step)
                }
                ordered[index] = step
            } catch {
                let reason = JobFailureReason.classify(error)
                let userMessage = reason.lastAttemptMessage(detail: error.localizedDescription)
                step.status = JobStepStatus.failed.rawValue
                step.errorMessage = userMessage
                step.finishedAt = Date()
                try? await repo.updateStep(step)
                await failJob(
                    repo: repo,
                    job: job,
                    steps: ordered,
                    failedStep: step,
                    reason: reason,
                    detail: error.localizedDescription
                )
                return
            }
        }

        try? await repo.updateJobStatus(id: job.id, status: JobStatus.succeeded.rawValue)
        await JobServiceStore.shared.log(
            level: .info,
            message: "job succeeded id=\(job.id)",
            code: "job_ok"
        )
    }

    private func failJob(
        repo: DBRepository,
        job: JobRow,
        steps: [JobStepRow],
        failedStep: JobStepRow?,
        reason: JobFailureReason,
        detail: String? = nil
    ) async {
        let message = reason.lastAttemptMessage(detail: detail)
        try? await repo.updateJobStatus(
            id: job.id,
            status: JobStatus.failed.rawValue,
            errorMessage: message,
            errorCode: reason.rawValue
        )
        await JobServiceStore.shared.log(
            level: .error,
            message: "job failed id=\(job.id) code=\(reason.rawValue): \(message)",
            code: "job_failed"
        )
        fputs("[JobService] job failed id=\(job.id) code=\(reason.rawValue): \(message)\n", stderr)
        await JobFailureUserReporter.report(
            job: job,
            steps: steps,
            failedStep: failedStep,
            reason: reason,
            detail: detail
        )
    }

    private func runToolStep(payloadJSON: String, principalJSON: String) async throws -> String {
        let payload = try JSONDecoder.service.decode(
            JobRunToolPayload.self,
            from: Data(payloadJSON.utf8)
        )
        let principal = try JSONDecoder.service.decode(
            ServicePrincipal.self,
            from: Data(principalJSON.utf8)
        )
        // Do not ServiceEnsureUp.ensureMCP() here: sibling XPC cannot serviceName-launch MCPService
        // and that path hangs. UI installs MCP peer before jobs run.
        guard JobMCPClient.shared.hasPeerEndpoint else {
            throw JobServiceError.stepFailed(
                "MCP peer mesh not installed on this JobService (UI handoff required)"
            )
        }
        fputs("[JobService] runTool \(payload.toolName)\n", stderr)
        let request = MCPToolCallRequest(
            principal: principal,
            toolName: payload.toolName,
            argumentsJSON: payload.argumentsJSON,
            helperAPIKey: payload.helperAPIKey,
            helperReviewerModelJSON: payload.helperReviewerModelJSON
        )
        let result = try await JobMCPClient.shared.callTool(request)
        fputs(
            "[JobService] runTool done tool=\(payload.toolName) ok=\(result.ok) isError=\(result.isError)\n",
            stderr
        )
        try validateToolResult(result, toolName: payload.toolName)
        let data = try JSONEncoder.service.encode(result)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func validateToolResult(_ result: MCPToolCallResultDTO, toolName: String) throws {
        guard result.ok else {
            let message = result.message.isEmpty ? "MCP tool call failed (\(toolName))" : result.message
            fputs("[JobService] runTool failed transport ok=false tool=\(toolName) message=\(message)\n", stderr)
            throw JobServiceError.stepFailed(message)
        }
        guard !result.isError else {
            let detail: String
            if !result.message.isEmpty, result.message != "tool reported error" {
                detail = result.message
            } else {
                detail = String(result.text.prefix(500))
            }
            let message = detail.isEmpty ? "tool \(toolName) reported error" : detail
            fputs("[JobService] runTool failed isError=true tool=\(toolName) detail=\(message.prefix(200))\n", stderr)
            throw JobServiceError.stepFailed(message)
        }
    }

    private func runToolBatchStep(payloadJSON: String, principalJSON: String) async throws -> String {
        let payload = try JSONDecoder.service.decode(
            JobRunToolBatchPayload.self,
            from: Data(payloadJSON.utf8)
        )
        var results: [MCPToolCallResultDTO] = []
        for inv in payload.invocations {
            let one = try JSONEncoder.service.encode(inv)
            let json = String(data: one, encoding: .utf8) ?? "{}"
            let text = try await runToolStep(payloadJSON: json, principalJSON: principalJSON)
            if let data = text.data(using: .utf8),
               let dto = try? JSONDecoder.service.decode(MCPToolCallResultDTO.self, from: data)
            {
                results.append(dto)
            }
        }
        let data = try JSONEncoder.service.encode(results)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func wakeAgentStep(payloadJSON: String) async throws -> String {
        let payload = try JSONDecoder.service.decode(
            JobWakeAgentPayload.self,
            from: Data(payloadJSON.utf8)
        )
        // Do not ServiceEnsureUp.ensureAgent() — sibling XPC hang; require peer mesh.
        guard JobAgentClient.shared.hasPeerEndpoint else {
            throw JobServiceError.stepFailed(
                "Agent peer mesh not installed on this JobService (UI handoff required)"
            )
        }
        fputs("[JobService] wakeAgent session=\(payload.sessionID ?? "?")\n", stderr)
        let accepted = try await JobAgentClient.shared.wakeAgent(payload: payload)
        guard accepted.ok else {
            throw JobServiceError.stepFailed(
                accepted.message.isEmpty ? "AgentService rejected wakeAgent turn" : accepted.message
            )
        }
        fputs("[JobService] wakeAgent accepted turn=\(accepted.turnID)\n", stderr)
        let data = try JSONEncoder.service.encode(accepted)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func runToolThenWakeStep(payloadJSON: String, principalJSON: String) async throws -> String {
        let payload = try JSONDecoder.service.decode(
            JobRunToolThenWakePayload.self,
            from: Data(payloadJSON.utf8)
        )
        let toolJSON = String(data: try JSONEncoder.service.encode(payload.tool), encoding: .utf8) ?? "{}"
        let toolResult = try await runToolStep(payloadJSON: toolJSON, principalJSON: principalJSON)
        // Append tool result into wake prompt so the agent sees the outcome.
        var wake = payload.wake
        let combinedPrompt = """
        \(wake.prompt)

        [job tool result]
        \(toolResult)
        """
        wake = JobWakeAgentPayload(
            prompt: combinedPrompt,
            sessionID: wake.sessionID,
            agentID: wake.agentID ?? JobSessionID.agentID,
            modelJSON: wake.modelJSON,
            apiKey: wake.apiKey,
            jobID: wake.jobID,
            parentSessionID: wake.parentSessionID
        )
        let wakeJSON = String(data: try JSONEncoder.service.encode(wake), encoding: .utf8) ?? "{}"
        let wakeResult = try await wakeAgentStep(payloadJSON: wakeJSON)
        return #"{"toolResult":\#(toolResult.jsonEscapedForEmbedding),"wake":\#(wakeResult.jsonEscapedForEmbedding)}"#
    }
}

private extension String {
    var jsonEscapedForEmbedding: String {
        let data = try? JSONEncoder().encode(self)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}
