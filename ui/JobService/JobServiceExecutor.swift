import Foundation
import DBRepository
import ServiceContracts
import ServiceEnsureUp

/// Runs claimed job steps. Tool execution uses MCP ensure-up + XPC callTool (signed).
actor JobServiceExecutor {
    static let shared = JobServiceExecutor()

    func execute(job: JobRow, steps: [JobStepRow]) async {
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
                await failJob(repo: repo, jobID: job.id, message: "unknown step kind \(step.kind)")
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
                step.status = JobStepStatus.failed.rawValue
                step.errorMessage = error.localizedDescription
                step.finishedAt = Date()
                try? await repo.updateStep(step)
                await failJob(repo: repo, jobID: job.id, message: error.localizedDescription)
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

    private func failJob(repo: DBRepository, jobID: String, message: String) async {
        try? await repo.updateJobStatus(id: jobID, status: JobStatus.failed.rawValue, errorMessage: message)
        await JobServiceStore.shared.log(
            level: .error,
            message: "job failed id=\(jobID): \(message)",
            code: "job_failed"
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
        _ = try await ServiceEnsureUp.shared.ensureMCP()
        let request = MCPToolCallRequest(
            principal: principal,
            toolName: payload.toolName,
            argumentsJSON: payload.argumentsJSON,
            helperAPIKey: payload.helperAPIKey,
            helperReviewerModelJSON: payload.helperReviewerModelJSON
        )
        let result = try await JobMCPClient.shared.callTool(request)
        let data = try JSONEncoder.service.encode(result)
        return String(data: data, encoding: .utf8) ?? "{}"
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
        _ = try await ServiceEnsureUp.shared.ensureAgent()
        let accepted = try await JobAgentClient.shared.wakeAgent(payload: payload)
        guard accepted.ok else {
            throw JobServiceError.stepFailed(
                accepted.message.isEmpty ? "AgentService rejected wakeAgent turn" : accepted.message
            )
        }
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
            agentID: wake.agentID,
            modelJSON: wake.modelJSON,
            apiKey: wake.apiKey
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
