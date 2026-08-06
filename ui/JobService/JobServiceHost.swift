import Foundation
import DBRepository
import ServiceContracts

/// Create / cancel / query jobs in the shared DB.
actor JobServiceHost {
    static let shared = JobServiceHost()

    func createJob(_ request: CreateJobRequest) async throws -> JobRecord {
        let repo = try await JobServiceStore.shared.sharedRepository()
        let (jobRow, stepRows) = try JobServiceMapping.rows(from: request)
        try await repo.insertJob(jobRow, steps: stepRows)
        await JobServiceStore.shared.log(
            level: .info,
            message: "createJob id=\(jobRow.id) steps=\(stepRows.count) runAt=\(jobRow.runAt?.description ?? "now")",
            code: "create_job"
        )
        guard let loaded = try await repo.fetchJob(id: jobRow.id) else {
            throw JobServiceError.notFound(jobRow.id)
        }
        return try JobServiceMapping.jobRecord(from: loaded.0, steps: loaded.1)
    }

    func cancelJob(jobID: String) async throws {
        let repo = try await JobServiceStore.shared.sharedRepository()
        guard let loaded = try await repo.fetchJob(id: jobID) else {
            throw JobServiceError.notFound(jobID)
        }
        let status = loaded.0.status
        if status == JobStatus.succeeded.rawValue
            || status == JobStatus.failed.rawValue
            || status == JobStatus.cancelled.rawValue
        {
            return
        }
        try await repo.updateJobStatus(id: jobID, status: JobStatus.cancelled.rawValue)
        await JobServiceStore.shared.log(
            level: .info,
            message: "cancelJob id=\(jobID)",
            code: "cancel_job"
        )
    }

    func getJob(jobID: String) async throws -> JobRecord {
        let repo = try await JobServiceStore.shared.sharedRepository()
        guard let loaded = try await repo.fetchJob(id: jobID) else {
            throw JobServiceError.notFound(jobID)
        }
        return try JobServiceMapping.jobRecord(from: loaded.0, steps: loaded.1)
    }

    func listJobs(request: ListJobsRequest) async throws -> [JobRecord] {
        let repo = try await JobServiceStore.shared.sharedRepository()
        let rows = try await repo.listJobs(status: request.status?.rawValue, limit: request.limit)
        return try rows.map { try JobServiceMapping.jobRecord(from: $0.0, steps: $0.1) }
    }
}
