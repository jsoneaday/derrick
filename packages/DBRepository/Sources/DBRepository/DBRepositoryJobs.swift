import Foundation
import SQLite3

/// Persistence rows for JobService (domain mapping to ServiceContracts lives in JobService).
public struct JobRow: Sendable, Hashable {
    public let id: String
    public var status: String
    public let principalJSON: String
    public let source: String
    public let correlationID: String?
    public var runAt: Date?
    public let createdAt: Date
    public var updatedAt: Date
    public var errorMessage: String?

    public init(
        id: String,
        status: String,
        principalJSON: String,
        source: String,
        correlationID: String?,
        runAt: Date?,
        createdAt: Date,
        updatedAt: Date,
        errorMessage: String?
    ) {
        self.id = id
        self.status = status
        self.principalJSON = principalJSON
        self.source = source
        self.correlationID = correlationID
        self.runAt = runAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.errorMessage = errorMessage
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
                    id, status, principal_json, source, correlation_id,
                    run_at, created_at, updated_at, error_message
                ) VALUES (
                    \(quoted(job.id)),
                    \(quoted(job.status)),
                    \(quoted(job.principalJSON)),
                    \(quoted(job.source)),
                    \(sqlValue(job.correlationID)),
                    \(sqlValue(job.runAt.map { Self.iso8601Formatter().string(from: $0) })),
                    \(quoted(Self.iso8601Formatter().string(from: job.createdAt))),
                    \(quoted(Self.iso8601Formatter().string(from: job.updatedAt))),
                    \(sqlValue(job.errorMessage))
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
                SELECT id, status, principal_json, source, correlation_id,
                       run_at, created_at, updated_at, error_message
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

    func listJobs(status: String? = nil, limit: Int = 50) throws -> [(JobRow, [JobStepRow])] {
        let cap = max(1, min(limit, 500))
        return try withDatabaseHandle { handle in
            let sql: String
            if let status, !status.isEmpty {
                sql = """
                SELECT id, status, principal_json, source, correlation_id,
                       run_at, created_at, updated_at, error_message
                FROM jobs WHERE status = \(quoted(status))
                ORDER BY created_at DESC LIMIT \(cap);
                """
            } else {
                sql = """
                SELECT id, status, principal_json, source, correlation_id,
                       run_at, created_at, updated_at, error_message
                FROM jobs
                ORDER BY created_at DESC LIMIT \(cap);
                """
            }
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
                    SELECT id, status, principal_json, source, correlation_id,
                           run_at, created_at, updated_at, error_message
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

    func updateJobStatus(id: String, status: String, errorMessage: String? = nil, updatedAt: Date = .now) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            UPDATE jobs SET
                status = \(quoted(status)),
                error_message = \(sqlValue(errorMessage)),
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
                    runAt: columnOptionalText(statement, 5).flatMap { iso8601Formatter().date(from: $0) },
                    createdAt: iso8601Formatter().date(from: columnText(statement, 6)) ?? .now,
                    updatedAt: iso8601Formatter().date(from: columnText(statement, 7)) ?? .now,
                    errorMessage: columnOptionalText(statement, 8)
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
