import Foundation
import DBRepository
import ServiceContracts

/// Create / cancel / query jobs and schedules in the shared DB.
actor JobServiceHost {
    static let shared = JobServiceHost()

    // MARK: - Jobs (runs)

    func createJob(_ request: CreateJobRequest) async throws -> JobRecord {
        let repo = try await JobServiceStore.shared.sharedRepository()
        let (jobRow, stepRows) = try JobServiceMapping.rows(from: request)
        try await repo.insertJob(jobRow, steps: stepRows)
        await JobServiceStore.shared.log(
            level: .info,
            message: "createJob id=\(jobRow.id) schedule=\(jobRow.scheduleID ?? "-") steps=\(stepRows.count) runAt=\(jobRow.runAt?.description ?? "now")",
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
        let rows = try await repo.listJobs(
            status: request.status?.rawValue,
            scheduleID: request.scheduleID,
            limit: request.limit
        )
        return try rows.map { try JobServiceMapping.jobRecord(from: $0.0, steps: $0.1) }
    }

    // MARK: - Schedules

    func createSchedule(_ request: CreateScheduleRequest) async throws -> JobScheduleRecord {
        let repo = try await JobServiceStore.shared.sharedRepository()
        let row = try JobServiceMapping.scheduleRow(from: request)
        try await repo.insertSchedule(row)
        await JobServiceStore.shared.log(
            level: .info,
            message: "createSchedule id=\(row.id) name=\(row.name) recurrence=\(row.recurrenceKind) next=\(row.nextFireAt?.description ?? "nil")",
            code: "create_schedule"
        )
        return try JobServiceMapping.scheduleRecord(from: row)
    }

    func updateSchedule(_ request: UpdateScheduleRequest) async throws -> JobScheduleRecord {
        let repo = try await JobServiceStore.shared.sharedRepository()
        guard let existing = try await repo.fetchSchedule(id: request.scheduleID) else {
            throw JobServiceError.notFound(request.scheduleID)
        }
        let updated = try JobServiceMapping.applyUpdate(request, to: existing)
        try await repo.updateSchedule(updated)
        await JobServiceStore.shared.log(
            level: .info,
            message: "updateSchedule id=\(updated.id) enabled=\(updated.enabled)",
            code: "update_schedule"
        )
        return try JobServiceMapping.scheduleRecord(from: updated)
    }

    func setScheduleEnabled(scheduleID: String, enabled: Bool) async throws -> JobScheduleRecord {
        try await updateSchedule(
            UpdateScheduleRequest(scheduleID: scheduleID, enabled: enabled)
        )
    }

    func deleteSchedule(scheduleID: String) async throws {
        let repo = try await JobServiceStore.shared.sharedRepository()
        guard try await repo.fetchSchedule(id: scheduleID) != nil else {
            throw JobServiceError.notFound(scheduleID)
        }
        try await repo.deleteSchedule(id: scheduleID)
        await JobServiceStore.shared.log(
            level: .info,
            message: "deleteSchedule id=\(scheduleID)",
            code: "delete_schedule"
        )
    }

    func getSchedule(scheduleID: String) async throws -> JobScheduleRecord {
        let repo = try await JobServiceStore.shared.sharedRepository()
        guard let row = try await repo.fetchSchedule(id: scheduleID) else {
            throw JobServiceError.notFound(scheduleID)
        }
        return try JobServiceMapping.scheduleRecord(from: row)
    }

    func listSchedules(request: ListSchedulesRequest) async throws -> [JobScheduleRecord] {
        let repo = try await JobServiceStore.shared.sharedRepository()
        let rows = try await repo.listSchedules(enabledOnly: request.enabledOnly, limit: request.limit)
        return try rows.map { try JobServiceMapping.scheduleRecord(from: $0) }
    }

    /// Spawn a pending job from a claimed schedule template.
    func spawnJob(from schedule: JobScheduleRow) async throws -> JobRecord {
        let request = try JobServiceMapping.jobRequest(from: schedule)
        return try await createJob(request)
    }
}
