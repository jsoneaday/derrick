import Foundation
import DBRepository
import ServiceContracts

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
            runAt: job.runAt,
            createdAt: job.createdAt,
            updatedAt: job.updatedAt,
            errorMessage: job.errorMessage,
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
            runAt: request.runAt,
            createdAt: now,
            updatedAt: now,
            errorMessage: nil
        )
        let steps = request.steps.enumerated().map { index, spec in
            JobStepRow(
                id: UUID().uuidString,
                jobID: jobID,
                index: index,
                kind: spec.kind.rawValue,
                status: JobStepStatus.pending.rawValue,
                payloadJSON: spec.payloadJSON
            )
        }
        return (job, steps)
    }
}

enum JobServiceError: Error, LocalizedError {
    case invalidRecord(String)
    case notFound(String)
    case stepFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRecord(let m): return m
        case .notFound(let id): return "Job not found: \(id)"
        case .stepFailed(let m): return m
        }
    }
}
