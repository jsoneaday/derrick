import Foundation
import DBRepository
import Structure

enum JobServiceMapping {
    static func jobRecord(from job: JobRow, steps: [JobStepRow]) throws -> JobRecord {
        let principal = try JSONDecoder.service.decode(ServicePrincipal.self, from: Data(job.principalJSON.utf8))
        guard let source = JobSource(rawValue: job.source) else {
            throw JobServiceError.invalidRecord("unknown source \(job.source)")
        }
        guard let status = JobStatus(rawValue: job.status) else {
            throw JobServiceError.invalidRecord("unknown status \(job.status)")
        }
        let stepRecords = try steps.map { step -> JobStepRecord in
            guard let kind = JobStepKind(rawValue: step.kind) else {
                throw JobServiceError.invalidRecord("unknown step kind \(step.kind)")
            }
            guard let stepStatus = JobStepStatus(rawValue: step.status) else {
                throw JobServiceError.invalidRecord("unknown step status \(step.status)")
            }
            return JobStepRecord(
                id: step.id,
                jobID: step.jobID,
                index: step.index,
                kind: kind,
                status: stepStatus,
                payloadJSON: step.payloadJSON,
                resultJSON: step.resultJSON,
                errorMessage: step.errorMessage,
                startedAt: step.startedAt,
                finishedAt: step.finishedAt
            )
        }
        return JobRecord(
            id: job.id,
            status: status,
            principal: principal,
            source: source,
            correlationId: job.correlationID,
            scheduleID: job.scheduleID,
            runAt: job.runAt,
            createdAt: job.createdAt,
            updatedAt: job.updatedAt,
            errorMessage: job.errorMessage,
            errorCode: job.errorCode,
            statusDetail: job.statusDetail,
            steps: stepRecords
        )
    }

    static func rows(from request: CreateJobRequest) throws -> (JobRow, [JobStepRow]) {
        guard !request.steps.isEmpty else {
            throw JobServiceError.invalidRecord("job must have at least one step")
        }
        let jobID = UUID().uuidString
        let now = Date()
        let principalData = try JSONEncoder.service.encode(request.principal)
        let principalJSON = String(data: principalData, encoding: .utf8) ?? "{}"
        let status: JobStatus = request.runAt == nil ? .pending : .scheduled
        let job = JobRow(
            id: jobID,
            status: status.rawValue,
            principalJSON: principalJSON,
            source: request.source.rawValue,
            correlationID: request.correlationId,
            scheduleID: request.scheduleID,
            runAt: request.runAt,
            createdAt: now,
            updatedAt: now,
            errorMessage: nil
        )
        let steps = request.steps.enumerated().map { index, spec in
            let payloadJSON = (try? Self.injectJobID(into: spec.payloadJSON, kind: spec.kind, jobID: jobID))
                ?? spec.payloadJSON
            return JobStepRow(
                id: UUID().uuidString,
                jobID: jobID,
                index: index,
                kind: spec.kind.rawValue,
                status: JobStepStatus.pending.rawValue,
                payloadJSON: payloadJSON
            )
        }
        return (job, steps)
    }

    /// Stamp durable job id onto wake payloads after the job row id is assigned.
    private static func injectJobID(into payloadJSON: String, kind: JobStepKind, jobID: String) throws -> String {
        switch kind {
        case .wakeAgent:
            var wake = try JSONDecoder.service.decode(JobWakeAgentPayload.self, from: Data(payloadJSON.utf8))
            wake = JobWakeAgentPayload(
                prompt: wake.prompt,
                sessionID: wake.sessionID,
                agentID: wake.agentID,
                modelJSON: wake.modelJSON,
                apiKey: wake.apiKey,
                jobID: jobID,
                parentSessionID: wake.parentSessionID
            )
            let data = try JSONEncoder.service.encode(wake)
            return String(data: data, encoding: .utf8) ?? payloadJSON
        case .runToolThenWake:
            var combined = try JSONDecoder.service.decode(
                JobRunToolThenWakePayload.self,
                from: Data(payloadJSON.utf8)
            )
            let wake = combined.wake
            combined = JobRunToolThenWakePayload(
                tool: combined.tool,
                wake: JobWakeAgentPayload(
                    prompt: wake.prompt,
                    sessionID: wake.sessionID,
                    agentID: wake.agentID,
                    modelJSON: wake.modelJSON,
                    apiKey: wake.apiKey,
                    jobID: jobID,
                    parentSessionID: wake.parentSessionID
                )
            )
            let data = try JSONEncoder.service.encode(combined)
            return String(data: data, encoding: .utf8) ?? payloadJSON
        default:
            return payloadJSON
        }
    }

    static func scheduleRecord(from row: JobScheduleRow) throws -> JobScheduleRecord {
        let principal = try JSONDecoder.service.decode(ServicePrincipal.self, from: Data(row.principalJSON.utf8))
        guard let source = JobSource(rawValue: row.source) else {
            throw JobServiceError.invalidRecord("unknown schedule source \(row.source)")
        }
        guard let kind = JobRecurrenceKind(rawValue: row.recurrenceKind) else {
            throw JobServiceError.invalidRecord("unknown recurrence \(row.recurrenceKind)")
        }
        let steps = try JSONDecoder.service.decode([CreateJobStepSpec].self, from: Data(row.stepsJSON.utf8))
        return JobScheduleRecord(
            id: row.id,
            name: row.name,
            enabled: row.enabled,
            principal: principal,
            source: source,
            recurrence: JobRecurrence(kind: kind, intervalSeconds: row.intervalSeconds),
            steps: steps,
            nextFireAt: row.nextFireAt,
            lastFiredAt: row.lastFiredAt,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt
        )
    }

    static func scheduleRow(from request: CreateScheduleRequest) throws -> JobScheduleRow {
        guard !request.steps.isEmpty else {
            throw JobServiceError.invalidRecord("schedule must have at least one step")
        }
        if request.recurrence.kind == .interval {
            guard let seconds = request.recurrence.intervalSeconds, seconds >= 60 else {
                throw JobServiceError.invalidRecord("interval schedules require intervalSeconds >= 60")
            }
        }
        let now = Date()
        let principalData = try JSONEncoder.service.encode(request.principal)
        let principalJSON = String(data: principalData, encoding: .utf8) ?? "{}"
        let stepsData = try JSONEncoder.service.encode(request.steps)
        let stepsJSON = String(data: stepsData, encoding: .utf8) ?? "[]"
        let nextFire = request.nextFireAt ?? (request.enabled ? now : nil)
        return JobScheduleRow(
            id: UUID().uuidString,
            name: request.name,
            enabled: request.enabled,
            principalJSON: principalJSON,
            source: request.source.rawValue,
            recurrenceKind: request.recurrence.kind.rawValue,
            intervalSeconds: request.recurrence.intervalSeconds,
            stepsJSON: stepsJSON,
            nextFireAt: nextFire,
            lastFiredAt: nil,
            createdAt: now,
            updatedAt: now
        )
    }

    static func applyUpdate(_ request: UpdateScheduleRequest, to row: JobScheduleRow) throws -> JobScheduleRow {
        var updated = row
        if let name = request.name { updated.name = name }
        if let enabled = request.enabled { updated.enabled = enabled }
        if let recurrence = request.recurrence {
            if recurrence.kind == .interval {
                guard let seconds = recurrence.intervalSeconds, seconds >= 60 else {
                    throw JobServiceError.invalidRecord("interval schedules require intervalSeconds >= 60")
                }
            }
            updated.recurrenceKind = recurrence.kind.rawValue
            updated.intervalSeconds = recurrence.intervalSeconds
        }
        if let steps = request.steps {
            guard !steps.isEmpty else {
                throw JobServiceError.invalidRecord("schedule must have at least one step")
            }
            let data = try JSONEncoder.service.encode(steps)
            updated.stepsJSON = String(data: data, encoding: .utf8) ?? "[]"
        }
        if let next = request.nextFireAt {
            updated.nextFireAt = next
        }
        // Re-enable with no next fire → fire ASAP
        if request.enabled == true, updated.nextFireAt == nil {
            updated.nextFireAt = Date()
        }
        updated.updatedAt = Date()
        return updated
    }

    /// Build a one-shot job create request from a schedule template.
    static func jobRequest(from schedule: JobScheduleRow) throws -> CreateJobRequest {
        let principal = try JSONDecoder.service.decode(ServicePrincipal.self, from: Data(schedule.principalJSON.utf8))
        guard let source = JobSource(rawValue: schedule.source) else {
            throw JobServiceError.invalidRecord("unknown source")
        }
        let steps = try JSONDecoder.service.decode([CreateJobStepSpec].self, from: Data(schedule.stepsJSON.utf8))
        return CreateJobRequest(
            principal: principal,
            source: source,
            correlationId: schedule.id,
            scheduleID: schedule.id,
            runAt: nil,
            steps: steps
        )
    }
}

enum JobServiceError: Error, LocalizedError {
    case invalidRecord(String)
    case notFound(String)
    case stepFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRecord(let m): return m
        case .notFound(let id): return "Not found: \(id)"
        case .stepFailed(let m): return m
        }
    }
}
