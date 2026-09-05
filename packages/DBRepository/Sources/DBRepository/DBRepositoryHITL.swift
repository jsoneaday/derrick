import Foundation
import SQLite3
import Structure

extension DBRepository {
    public func insertPendingHITLApproval(_ row: PendingHITLApprovalRow) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            INSERT INTO pending_hitl_approvals (
                id, turn_id, session_id, tool_name, arguments_json, required_fields_json,
                status, edited_arguments_json, actor, notify_posted, is_job_context, created_at, decided_at
            ) VALUES (
                \(quoted(row.id)),
                \(quoted(row.turnID)),
                \(quoted(row.sessionID)),
                \(quoted(row.toolName)),
                \(quoted(row.argumentsJSON)),
                \(quoted(row.requiredFieldsJSON)),
                \(quoted(row.status.rawValue)),
                \(sqlValue(row.editedArgumentsJSON)),
                \(sqlValue(row.actor)),
                \(row.notifyPosted ? 1 : 0),
                \(row.isJobContext ? 1 : 0),
                \(quoted(Self.iso8601Formatter().string(from: row.createdAt))),
                \(sqlValue(row.decidedAt.map { Self.iso8601Formatter().string(from: $0) }))
            );
            """, on: handle)
        }
    }

    private static let hitlSelectColumns = """
    id, turn_id, session_id, tool_name, arguments_json, required_fields_json,
    status, edited_arguments_json, actor, notify_posted, is_job_context, created_at, decided_at
    """

    public func fetchPendingHITLApproval(id: String) throws -> PendingHITLApprovalRow? {
        try withDatabaseHandle { handle in
            let rows = try Self.fetchHITLApprovals(
                sql: """
                SELECT \(Self.hitlSelectColumns)
                FROM pending_hitl_approvals
                WHERE id = \(quoted(id))
                LIMIT 1;
                """,
                on: handle
            )
            return rows.first
        }
    }

    public func fetchPendingHITLApprovalsNeedingNotify(limit: Int = 10) throws -> [PendingHITLApprovalRow] {
        let cap = max(1, min(limit, 50))
        return try withDatabaseHandle { handle in
            try Self.fetchHITLApprovals(
                sql: """
                SELECT \(Self.hitlSelectColumns)
                FROM pending_hitl_approvals
                WHERE status = 'pending' AND notify_posted = 0
                ORDER BY created_at ASC
                LIMIT \(cap);
                """,
                on: handle
            )
        }
    }

    public func fetchOpenPendingHITLApprovals(limit: Int = 20) throws -> [PendingHITLApprovalRow] {
        let cap = max(1, min(limit, 50))
        return try withDatabaseHandle { handle in
            try Self.fetchHITLApprovals(
                sql: """
                SELECT \(Self.hitlSelectColumns)
                FROM pending_hitl_approvals
                WHERE status = 'pending'
                ORDER BY created_at ASC
                LIMIT \(cap);
                """,
                on: handle
            )
        }
    }

    public func markHITLApprovalNotified(id: String) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            UPDATE pending_hitl_approvals SET notify_posted = 1
            WHERE id = \(quoted(id)) AND status = 'pending';
            """, on: handle)
        }
    }

    /// Atomically marks `notify_posted` when still pending. Returns false if already claimed.
    public func claimHITLNotificationPost(id: String) throws -> Bool {
        try withDatabaseHandle { handle in
            try Self.execute("""
            UPDATE pending_hitl_approvals SET notify_posted = 1
            WHERE id = \(quoted(id)) AND status = 'pending' AND notify_posted = 0;
            """, on: handle)
            return sqlite3_changes(handle) > 0
        }
    }

    /// Reverts `claimHITLNotificationPost` so a failed post can be retried.
    public func resetHITLNotificationClaim(id: String) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            UPDATE pending_hitl_approvals SET notify_posted = 0
            WHERE id = \(quoted(id)) AND status = 'pending';
            """, on: handle)
        }
    }

    public func resolveHITLApproval(
        id: String,
        status: PendingHITLApprovalStatus,
        editedArgumentsJSON: String?,
        actor: String?,
        at date: Date = .now
    ) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            UPDATE pending_hitl_approvals SET
                status = \(quoted(status.rawValue)),
                edited_arguments_json = \(sqlValue(editedArgumentsJSON)),
                actor = \(sqlValue(actor)),
                decided_at = \(quoted(Self.iso8601Formatter().string(from: date)))
            WHERE id = \(quoted(id)) AND status = 'pending';
            """, on: handle)
        }
    }

    /// Cancels pending approvals created before the given time (stale rows from a prior session).
    @discardableResult
    public func cancelPendingHITLApprovals(createdBefore: Date, actor: String, at date: Date = .now) throws -> Int {
        try withDatabaseHandle { handle in
            try Self.execute("""
            UPDATE pending_hitl_approvals SET
                status = 'cancelled',
                actor = \(quoted(actor)),
                decided_at = \(quoted(Self.iso8601Formatter().string(from: date)))
            WHERE status = 'pending' AND created_at < \(quoted(Self.iso8601Formatter().string(from: createdBefore)));
            """, on: handle)
            return Int(sqlite3_changes(handle))
        }
    }

    /// Open network prompt for a host (dedupe concurrent requests).
    public func fetchOpenPendingNetworkApproval(host: String, isJobContext: Bool) throws -> PendingHITLApprovalRow? {
        let toolName = "network:\(host)"
        return try withDatabaseHandle { handle in
            let rows = try Self.fetchHITLApprovals(
                sql: """
                SELECT \(Self.hitlSelectColumns)
                FROM pending_hitl_approvals
                WHERE status = 'pending'
                  AND tool_name = \(quoted(toolName))
                  AND is_job_context = \(isJobContext ? 1 : 0)
                ORDER BY created_at ASC
                LIMIT 1;
                """,
                on: handle
            )
            return rows.first
        }
    }

    private static func fetchHITLApprovals(sql: String, on handle: OpaquePointer) throws -> [PendingHITLApprovalRow] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DBRepositoryError.sqliteOperationFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [PendingHITLApprovalRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let statusRaw = hitlColumnText(statement, 6)
            rows.append(
                PendingHITLApprovalRow(
                    id: hitlColumnText(statement, 0),
                    turnID: hitlColumnText(statement, 1),
                    sessionID: hitlColumnText(statement, 2),
                    toolName: hitlColumnText(statement, 3),
                    argumentsJSON: hitlColumnText(statement, 4),
                    requiredFieldsJSON: hitlColumnText(statement, 5),
                    status: PendingHITLApprovalStatus(rawValue: statusRaw) ?? .pending,
                    editedArgumentsJSON: hitlColumnOptionalText(statement, 7),
                    actor: hitlColumnOptionalText(statement, 8),
                    notifyPosted: sqlite3_column_int(statement, 9) != 0,
                    isJobContext: sqlite3_column_int(statement, 10) != 0,
                    createdAt: iso8601Formatter().date(from: hitlColumnText(statement, 11)) ?? .now,
                    decidedAt: hitlColumnOptionalText(statement, 12).flatMap { iso8601Formatter().date(from: $0) }
                )
            )
        }
        return rows
    }

    private static func hitlColumnText(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: c)
    }

    private static func hitlColumnOptionalText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let c = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: c)
    }
}
