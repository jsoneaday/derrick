import Foundation
import SQLite3

/// Persistence rows for JobService (domain mapping to ServiceContracts lives in JobService).
public struct JobRow: Sendable, Hashable {
    public let id: String
    public var status: String
    public let principalJSON: String
    public let source: String
    public let correlationID: String?
    public let scheduleID: String?
    public var runAt: Date?
    public let createdAt: Date
    public var updatedAt: Date
    public var errorMessage: String?
    /// Stable code (e.g. JobFailureReason.rawValue).
    public var errorCode: String?
    /// Non-terminal note (e.g. started late after sleep).
    public var statusDetail: String?

    public init(
        id: String,
        status: String,
        principalJSON: String,
        source: String,
        correlationID: String?,
        scheduleID: String? = nil,
        runAt: Date?,
        createdAt: Date,
        updatedAt: Date,
        errorMessage: String?,
        errorCode: String? = nil,
        statusDetail: String? = nil
    ) {
        self.id = id
        self.status = status
        self.principalJSON = principalJSON
        self.source = source
        self.correlationID = correlationID
        self.scheduleID = scheduleID
        self.runAt = runAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.errorMessage = errorMessage
        self.errorCode = errorCode
        self.statusDetail = statusDetail
    }
}

public struct JobScheduleRow: Sendable, Hashable {
    public let id: String
    public var name: String
    public var enabled: Bool
    public let principalJSON: String
    public let source: String
    public var recurrenceKind: String
    public var intervalSeconds: Int?
    public var stepsJSON: String
    public var nextFireAt: Date?
    public var lastFiredAt: Date?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        enabled: Bool,
        principalJSON: String,
        source: String,
        recurrenceKind: String,
        intervalSeconds: Int?,
        stepsJSON: String,
        nextFireAt: Date?,
        lastFiredAt: Date?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.principalJSON = principalJSON
        self.source = source
        self.recurrenceKind = recurrenceKind
        self.intervalSeconds = intervalSeconds
        self.stepsJSON = stepsJSON
        self.nextFireAt = nextFireAt
        self.lastFiredAt = lastFiredAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct JobStepRow: Sendable, Hashable {
    public let id: String
    public let jobID: String
    public let index: Int
    public let kind: String
    public var status: String
    public let payloadJSON: String
    public var resultJSON: String?
    public var errorMessage: String?
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(
        id: String,
        jobID: String,
        index: Int,
        kind: String,
        status: String,
        payloadJSON: String,
        resultJSON: String? = nil,
        errorMessage: String? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.jobID = jobID
        self.index = index
        self.kind = kind
        self.status = status
        self.payloadJSON = payloadJSON
        self.resultJSON = resultJSON
        self.errorMessage = errorMessage
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public extension DBRepository {
    func insertJob(_ job: JobRow, steps: [JobStepRow]) throws {
        try withDatabaseHandle { handle in
            try Self.execute("BEGIN;", on: handle)
            do {
                try Self.execute("""
                INSERT INTO jobs (
                    id, status, principal_json, source, correlation_id, schedule_id,
                    run_at, created_at, updated_at, error_message, error_code, status_detail
                ) VALUES (
                    \(quoted(job.id)),
                    \(quoted(job.status)),
                    \(quoted(job.principalJSON)),
                    \(quoted(job.source)),
                    \(sqlValue(job.correlationID)),
                    \(sqlValue(job.scheduleID)),
                    \(sqlValue(job.runAt.map { Self.iso8601Formatter().string(from: $0) })),
                    \(quoted(Self.iso8601Formatter().string(from: job.createdAt))),
                    \(quoted(Self.iso8601Formatter().string(from: job.updatedAt))),
                    \(sqlValue(job.errorMessage)),
                    \(sqlValue(job.errorCode)),
                    \(sqlValue(job.statusDetail))
                );
                """, on: handle)
                for step in steps {
                    try Self.execute("""
                    INSERT INTO job_steps (
                        id, job_id, step_index, kind, status, payload_json,
                        result_json, error_message, started_at, finished_at
                    ) VALUES (
                        \(quoted(step.id)),
                        \(quoted(step.jobID)),
                        \(step.index),
                        \(quoted(step.kind)),
                        \(quoted(step.status)),
                        \(quoted(step.payloadJSON)),
                        \(sqlValue(step.resultJSON)),
                        \(sqlValue(step.errorMessage)),
                        \(sqlValue(step.startedAt.map { Self.iso8601Formatter().string(from: $0) })),
                        \(sqlValue(step.finishedAt.map { Self.iso8601Formatter().string(from: $0) }))
                    );
                    """, on: handle)
                }
                try Self.execute("COMMIT;", on: handle)
            } catch {
                try? Self.execute("ROLLBACK;", on: handle)
                throw error
            }
        }
    }

    func fetchJob(id: String) throws -> (JobRow, [JobStepRow])? {
        try withDatabaseHandle { handle in
            let jobs = try Self.fetchJobs(
                sql: """
                SELECT id, status, principal_json, source, correlation_id, schedule_id,
                       run_at, created_at, updated_at, error_message, error_code, status_detail
                FROM jobs WHERE id = \(quoted(id)) LIMIT 1;
                """,
                on: handle
            )
            guard let job = jobs.first else { return nil }
            let steps = try Self.fetchSteps(
                sql: """
                SELECT id, job_id, step_index, kind, status, payload_json,
                       result_json, error_message, started_at, finished_at
                FROM job_steps WHERE job_id = \(quoted(id))
                ORDER BY step_index ASC;
                """,
                on: handle
            )
            return (job, steps)
        }
    }

    public func fetchJobStatus(id: String) throws -> String? {
        try fetchJob(id: id)?.0.status
    }

    public func fetchJobFailureMessage(id: String) throws -> String? {
        try fetchJob(id: id)?.0.errorMessage
    }

    public func fetchJobErrorCode(id: String) throws -> String? {
        try fetchJob(id: id)?.0.errorCode
    }

    public func listRunningJobs(limit: Int = 50) throws -> [(JobRow, [JobStepRow])] {
        try listJobs(status: "running", limit: limit)
    }

    func listJobs(status: String? = nil, scheduleID: String? = nil, limit: Int = 50) throws -> [(JobRow, [JobStepRow])] {
        let cap = max(1, min(limit, 500))
        return try withDatabaseHandle { handle in
            var clauses: [String] = []
            if let status, !status.isEmpty {
                clauses.append("status = \(quoted(status))")
            }
            if let scheduleID, !scheduleID.isEmpty {
                clauses.append("schedule_id = \(quoted(scheduleID))")
            }
            let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            let sql = """
                SELECT id, status, principal_json, source, correlation_id, schedule_id,
                       run_at, created_at, updated_at, error_message, error_code, status_detail
                FROM jobs
                \(whereSQL)
                ORDER BY created_at DESC LIMIT \(cap);
                """
            let jobs = try Self.fetchJobs(sql: sql, on: handle)
            return try jobs.map { job in
                let steps = try Self.fetchSteps(
                    sql: """
                    SELECT id, job_id, step_index, kind, status, payload_json,
                           result_json, error_message, started_at, finished_at
                    FROM job_steps WHERE job_id = \(quoted(job.id))
                    ORDER BY step_index ASC;
                    """,
                    on: handle
                )
                return (job, steps)
            }
        }
    }

    /// Claim due jobs: status pending/scheduled and run_at is null or <= now.
    func claimDueJobs(limit: Int = 10, now: Date = .now) throws -> [(JobRow, [JobStepRow])] {
        let cap = max(1, min(limit, 50))
        let nowStr = Self.iso8601Formatter().string(from: now)
        return try withDatabaseHandle { handle in
            try Self.execute("BEGIN IMMEDIATE;", on: handle)
            do {
                let jobs = try Self.fetchJobs(
                    sql: """
                    SELECT id, status, principal_json, source, correlation_id, schedule_id,
                           run_at, created_at, updated_at, error_message, error_code, status_detail
                    FROM jobs
                    WHERE status IN ('pending', 'scheduled')
                      AND (run_at IS NULL OR run_at <= \(quoted(nowStr)))
                    ORDER BY COALESCE(run_at, created_at) ASC
                    LIMIT \(cap);
                    """,
                    on: handle
                )
                var claimed: [(JobRow, [JobStepRow])] = []
                for var job in jobs {
                    try Self.execute("""
                    UPDATE jobs SET status = 'running',
                        updated_at = \(quoted(nowStr))
                    WHERE id = \(quoted(job.id)) AND status IN ('pending', 'scheduled');
                    """, on: handle)
                    job.status = "running"
                    job.updatedAt = now
                    let steps = try Self.fetchSteps(
                        sql: """
                        SELECT id, job_id, step_index, kind, status, payload_json,
                               result_json, error_message, started_at, finished_at
                        FROM job_steps WHERE job_id = \(quoted(job.id))
                        ORDER BY step_index ASC;
                        """,
                        on: handle
                    )
                    claimed.append((job, steps))
                }
                try Self.execute("COMMIT;", on: handle)
                return claimed
            } catch {
                try? Self.execute("ROLLBACK;", on: handle)
                throw error
            }
        }
    }

    func updateJobStatus(
        id: String,
        status: String,
        errorMessage: String? = nil,
        errorCode: String? = nil,
        statusDetail: String? = nil,
        updatedAt: Date = .now
    ) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            UPDATE jobs SET
                status = \(quoted(status)),
                error_message = \(sqlValue(errorMessage)),
                error_code = \(sqlValue(errorCode)),
                status_detail = COALESCE(\(sqlValue(statusDetail)), status_detail),
                updated_at = \(quoted(Self.iso8601Formatter().string(from: updatedAt)))
            WHERE id = \(quoted(id));
            """, on: handle)
        }
    }

    /// Mark jobs left in `running` after process death / sleep as failed.
    func failInterruptedRunningJobs(
        errorMessage: String,
        errorCode: String,
        updatedAt: Date = .now
    ) throws -> Int {
        try withDatabaseHandle { handle in
            try Self.execute("""
            UPDATE jobs SET
                status = 'failed',
                error_message = \(quoted(errorMessage)),
                error_code = \(quoted(errorCode)),
                updated_at = \(quoted(Self.iso8601Formatter().string(from: updatedAt)))
            WHERE status = 'running';
            """, on: handle)
            return Int(sqlite3_changes(handle))
        }
    }

    func updateJobStatusDetail(id: String, statusDetail: String, updatedAt: Date = .now) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            UPDATE jobs SET
                status_detail = \(quoted(statusDetail)),
                updated_at = \(quoted(Self.iso8601Formatter().string(from: updatedAt)))
            WHERE id = \(quoted(id));
            """, on: handle)
        }
    }

    func updateStep(_ step: JobStepRow) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            UPDATE job_steps SET
                status = \(quoted(step.status)),
                result_json = \(sqlValue(step.resultJSON)),
                error_message = \(sqlValue(step.errorMessage)),
                started_at = \(sqlValue(step.startedAt.map { Self.iso8601Formatter().string(from: $0) })),
                finished_at = \(sqlValue(step.finishedAt.map { Self.iso8601Formatter().string(from: $0) }))
            WHERE id = \(quoted(step.id));
            """, on: handle)
        }
    }

    private static func fetchJobs(sql: String, on handle: OpaquePointer) throws -> [JobRow] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DBRepositoryError.sqliteOperationFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [JobRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                JobRow(
                    id: columnText(statement, 0),
                    status: columnText(statement, 1),
                    principalJSON: columnText(statement, 2),
                    source: columnText(statement, 3),
                    correlationID: columnOptionalText(statement, 4),
                    scheduleID: columnOptionalText(statement, 5),
                    runAt: columnOptionalText(statement, 6).flatMap { iso8601Formatter().date(from: $0) },
                    createdAt: iso8601Formatter().date(from: columnText(statement, 7)) ?? .now,
                    updatedAt: iso8601Formatter().date(from: columnText(statement, 8)) ?? .now,
                    errorMessage: columnOptionalText(statement, 9),
                    errorCode: columnOptionalText(statement, 10),
                    statusDetail: columnOptionalText(statement, 11)
                )
            )
        }
        return rows
    }

    // MARK: - Schedules

    func insertSchedule(_ row: JobScheduleRow) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            INSERT INTO job_schedules (
                id, name, enabled, principal_json, source,
                recurrence_kind, interval_seconds, steps_json,
                next_fire_at, last_fired_at, created_at, updated_at
            ) VALUES (
                \(quoted(row.id)),
                \(quoted(row.name)),
                \(row.enabled ? 1 : 0),
                \(quoted(row.principalJSON)),
                \(quoted(row.source)),
                \(quoted(row.recurrenceKind)),
                \(sqlValue(row.intervalSeconds)),
                \(quoted(row.stepsJSON)),
                \(sqlValue(row.nextFireAt.map { Self.iso8601Formatter().string(from: $0) })),
                \(sqlValue(row.lastFiredAt.map { Self.iso8601Formatter().string(from: $0) })),
                \(quoted(Self.iso8601Formatter().string(from: row.createdAt))),
                \(quoted(Self.iso8601Formatter().string(from: row.updatedAt)))
            );
            """, on: handle)
        }
    }

    func updateSchedule(_ row: JobScheduleRow) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            UPDATE job_schedules SET
                name = \(quoted(row.name)),
                enabled = \(row.enabled ? 1 : 0),
                recurrence_kind = \(quoted(row.recurrenceKind)),
                interval_seconds = \(sqlValue(row.intervalSeconds)),
                steps_json = \(quoted(row.stepsJSON)),
                next_fire_at = \(sqlValue(row.nextFireAt.map { Self.iso8601Formatter().string(from: $0) })),
                last_fired_at = \(sqlValue(row.lastFiredAt.map { Self.iso8601Formatter().string(from: $0) })),
                updated_at = \(quoted(Self.iso8601Formatter().string(from: row.updatedAt)))
            WHERE id = \(quoted(row.id));
            """, on: handle)
        }
    }

    func deleteSchedule(id: String) throws {
        try withDatabaseHandle { handle in
            try Self.execute("DELETE FROM job_schedules WHERE id = \(quoted(id));", on: handle)
        }
    }

    func fetchSchedule(id: String) throws -> JobScheduleRow? {
        try withDatabaseHandle { handle in
            let rows = try Self.fetchSchedules(
                sql: """
                SELECT id, name, enabled, principal_json, source,
                       recurrence_kind, interval_seconds, steps_json,
                       next_fire_at, last_fired_at, created_at, updated_at
                FROM job_schedules WHERE id = \(quoted(id)) LIMIT 1;
                """,
                on: handle
            )
            return rows.first
        }
    }

    func listSchedules(enabledOnly: Bool = false, limit: Int = 100) throws -> [JobScheduleRow] {
        let cap = max(1, min(limit, 500))
        return try withDatabaseHandle { handle in
            let whereSQL = enabledOnly ? "WHERE enabled = 1" : ""
            return try Self.fetchSchedules(
                sql: """
                SELECT id, name, enabled, principal_json, source,
                       recurrence_kind, interval_seconds, steps_json,
                       next_fire_at, last_fired_at, created_at, updated_at
                FROM job_schedules
                \(whereSQL)
                ORDER BY name ASC
                LIMIT \(cap);
                """,
                on: handle
            )
        }
    }

    /// Claim due schedules: enabled and next_fire_at <= now. Advances next_fire_at in same transaction.
    /// Returns claimed rows **before** advance (caller spawns jobs from template).
    func claimDueSchedules(
        limit: Int = 10,
        now: Date = .now,
        nextFire: @Sendable (JobScheduleRow, Date) -> (enabled: Bool, nextFireAt: Date?)
    ) throws -> [JobScheduleRow] {
        let cap = max(1, min(limit, 50))
        let nowStr = Self.iso8601Formatter().string(from: now)
        return try withDatabaseHandle { handle in
            try Self.execute("BEGIN IMMEDIATE;", on: handle)
            do {
                let due = try Self.fetchSchedules(
                    sql: """
                    SELECT id, name, enabled, principal_json, source,
                           recurrence_kind, interval_seconds, steps_json,
                           next_fire_at, last_fired_at, created_at, updated_at
                    FROM job_schedules
                    WHERE enabled = 1
                      AND next_fire_at IS NOT NULL
                      AND next_fire_at <= \(quoted(nowStr))
                    ORDER BY next_fire_at ASC
                    LIMIT \(cap);
                    """,
                    on: handle
                )
                var claimed: [JobScheduleRow] = []
                for row in due {
                    let advanced = nextFire(row, now)
                    var updated = row
                    updated.enabled = advanced.enabled
                    updated.nextFireAt = advanced.nextFireAt
                    updated.lastFiredAt = now
                    updated.updatedAt = now
                    try Self.execute("""
                    UPDATE job_schedules SET
                        enabled = \(updated.enabled ? 1 : 0),
                        next_fire_at = \(sqlValue(updated.nextFireAt.map { Self.iso8601Formatter().string(from: $0) })),
                        last_fired_at = \(quoted(nowStr)),
                        updated_at = \(quoted(nowStr))
                    WHERE id = \(quoted(row.id)) AND enabled = 1
                      AND next_fire_at IS NOT NULL AND next_fire_at <= \(quoted(nowStr));
                    """, on: handle)
                    claimed.append(row)
                }
                try Self.execute("COMMIT;", on: handle)
                return claimed
            } catch {
                try? Self.execute("ROLLBACK;", on: handle)
                throw error
            }
        }
    }

    private static func fetchSchedules(sql: String, on handle: OpaquePointer) throws -> [JobScheduleRow] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DBRepositoryError.sqliteOperationFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [JobScheduleRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                JobScheduleRow(
                    id: columnText(statement, 0),
                    name: columnText(statement, 1),
                    enabled: sqlite3_column_int(statement, 2) != 0,
                    principalJSON: columnText(statement, 3),
                    source: columnText(statement, 4),
                    recurrenceKind: columnText(statement, 5),
                    intervalSeconds: sqlite3_column_type(statement, 6) == SQLITE_NULL
                        ? nil
                        : Int(sqlite3_column_int(statement, 6)),
                    stepsJSON: columnText(statement, 7),
                    nextFireAt: columnOptionalText(statement, 8).flatMap { iso8601Formatter().date(from: $0) },
                    lastFiredAt: columnOptionalText(statement, 9).flatMap { iso8601Formatter().date(from: $0) },
                    createdAt: iso8601Formatter().date(from: columnText(statement, 10)) ?? .now,
                    updatedAt: iso8601Formatter().date(from: columnText(statement, 11)) ?? .now
                )
            )
        }
        return rows
    }

    // MARK: - Job results (wake completion for modal / notification)

    public struct JobResultRow: Sendable, Hashable {
        public let id: String
        public let jobID: String
        public let jobSessionID: String
        public let parentSessionID: String?
        public let responseText: String
        public let createdAt: Date
        public var readAt: Date?
        public var notifyPosted: Bool

        public init(
            id: String,
            jobID: String,
            jobSessionID: String,
            parentSessionID: String?,
            responseText: String,
            createdAt: Date,
            readAt: Date? = nil,
            notifyPosted: Bool = false
        ) {
            self.id = id
            self.jobID = jobID
            self.jobSessionID = jobSessionID
            self.parentSessionID = parentSessionID
            self.responseText = responseText
            self.createdAt = createdAt
            self.readAt = readAt
            self.notifyPosted = notifyPosted
        }
    }

    public func insertJobResult(_ row: JobResultRow) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            INSERT INTO job_results (
                id, job_id, job_session_id, parent_session_id, response_text, created_at, read_at, notify_posted
            ) VALUES (
                \(quoted(row.id)),
                \(quoted(row.jobID)),
                \(quoted(row.jobSessionID)),
                \(sqlValue(row.parentSessionID)),
                \(quoted(row.responseText)),
                \(quoted(Self.iso8601Formatter().string(from: row.createdAt))),
                \(sqlValue(row.readAt.map { Self.iso8601Formatter().string(from: $0) })),
                \(row.notifyPosted ? 1 : 0)
            );
            """, on: handle)
        }
    }

    public func markJobResultRead(id: String, at date: Date = .now) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            UPDATE job_results SET read_at = \(quoted(Self.iso8601Formatter().string(from: date)))
            WHERE id = \(quoted(id));
            """, on: handle)
        }
    }

    public func markJobResultNotified(id: String) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            UPDATE job_results SET notify_posted = 1 WHERE id = \(quoted(id));
            """, on: handle)
        }
    }

    /// Atomically marks `notify_posted` when still unposted.
    public func claimJobResultNotificationPost(id: String) throws -> Bool {
        try withDatabaseHandle { handle in
            try Self.execute("""
            UPDATE job_results SET notify_posted = 1 WHERE id = \(quoted(id)) AND notify_posted = 0;
            """, on: handle)
            return sqlite3_changes(handle) > 0
        }
    }

    /// Reverts `claimJobResultNotificationPost` so a failed post can be retried.
    public func resetJobResultNotificationClaim(id: String) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            UPDATE job_results SET notify_posted = 0 WHERE id = \(quoted(id));
            """, on: handle)
        }
    }

    public func hasPendingUserNotifications() throws -> Bool {
        try !fetchJobResultsNeedingNotify(limit: 1).isEmpty
            || !fetchPendingHITLApprovalsNeedingNotify(limit: 1).isEmpty
    }

    public func fetchJobResultsNeedingNotify(limit: Int = 20) throws -> [JobResultRow] {
        let cap = max(1, min(limit, 100))
        return try withDatabaseHandle { handle in
            try Self.fetchJobResults(
                sql: """
                SELECT id, job_id, job_session_id, parent_session_id, response_text, created_at, read_at, notify_posted
                FROM job_results
                WHERE notify_posted = 0
                ORDER BY created_at ASC
                LIMIT \(cap);
                """,
                on: handle
            )
        }
    }

    public func fetchUnreadJobResults(limit: Int = 20) throws -> [JobResultRow] {
        let cap = max(1, min(limit, 100))
        return try withDatabaseHandle { handle in
            try Self.fetchJobResults(
                sql: """
                SELECT id, job_id, job_session_id, parent_session_id, response_text, created_at, read_at, notify_posted
                FROM job_results
                WHERE read_at IS NULL
                ORDER BY created_at DESC
                LIMIT \(cap);
                """,
                on: handle
            )
        }
    }

    public func fetchJobResult(id: String) throws -> JobResultRow? {
        try withDatabaseHandle { handle in
            let rows = try Self.fetchJobResults(
                sql: """
                SELECT id, job_id, job_session_id, parent_session_id, response_text, created_at, read_at, notify_posted
                FROM job_results
                WHERE id = \(quoted(id))
                LIMIT 1;
                """,
                on: handle
            )
            return rows.first
        }
    }

    /// Scheduled fire time for a job run (`jobs.run_at`), if any.
    public func fetchJobRunAt(jobID: String) throws -> Date? {
        try fetchJob(id: jobID)?.0.runAt
    }

    /// True when work is waiting or in flight (daemon uses this to wake a headless UI worker).
    public func hasDueOrRunningJobs(now: Date = .now) throws -> Bool {
        let nowStr = Self.iso8601Formatter().string(from: now)
        return try withDatabaseHandle { handle in
            let sql = """
            SELECT COUNT(*) FROM jobs
            WHERE status = 'running'
               OR (
                    status IN ('pending', 'scheduled')
                AND (run_at IS NULL OR run_at <= \(quoted(nowStr)))
               );
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DBRepositoryError.sqliteOperationFailed(String(cString: sqlite3_errmsg(handle)))
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return false }
            return sqlite3_column_int(statement, 0) > 0
        }
    }

    private static func fetchJobResults(sql: String, on handle: OpaquePointer) throws -> [JobResultRow] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DBRepositoryError.sqliteOperationFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [JobResultRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                JobResultRow(
                    id: columnText(statement, 0),
                    jobID: columnText(statement, 1),
                    jobSessionID: columnText(statement, 2),
                    parentSessionID: columnOptionalText(statement, 3),
                    responseText: columnText(statement, 4),
                    createdAt: iso8601Formatter().date(from: columnText(statement, 5)) ?? .now,
                    readAt: columnOptionalText(statement, 6).flatMap { iso8601Formatter().date(from: $0) },
                    notifyPosted: sqlite3_column_int(statement, 7) != 0
                )
            )
        }
        return rows
    }

    private static func fetchSteps(sql: String, on handle: OpaquePointer) throws -> [JobStepRow] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DBRepositoryError.sqliteOperationFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [JobStepRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                JobStepRow(
                    id: columnText(statement, 0),
                    jobID: columnText(statement, 1),
                    index: Int(sqlite3_column_int(statement, 2)),
                    kind: columnText(statement, 3),
                    status: columnText(statement, 4),
                    payloadJSON: columnText(statement, 5),
                    resultJSON: columnOptionalText(statement, 6),
                    errorMessage: columnOptionalText(statement, 7),
                    startedAt: columnOptionalText(statement, 8).flatMap { iso8601Formatter().date(from: $0) },
                    finishedAt: columnOptionalText(statement, 9).flatMap { iso8601Formatter().date(from: $0) }
                )
            )
        }
        return rows
    }

    private static func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: c)
    }

    private static func columnOptionalText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let c = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: c)
    }
}
