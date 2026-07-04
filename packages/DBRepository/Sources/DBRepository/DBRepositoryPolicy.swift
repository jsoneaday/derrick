import Foundation
import SQLite3
@_exported import MemorySystem

public extension DBRepository {
    func loadPolicyRules(applicationName: String, scope: String) throws -> [PolicyRule] {
        try withDatabaseHandle { handle in
            try Self.execute("PRAGMA foreign_keys = ON;", on: handle)
            let sql = """
            SELECT id, application_name, name, scope, matcher_json, outcome_json, priority, enabled, created_at, updated_at
            FROM policy_rules
            WHERE application_name = \(quoted(applicationName))
              AND scope = \(quoted(scope))
              AND enabled = 1
            ORDER BY priority DESC, created_at DESC;
            """
            return try allPolicyRules(from: sql, on: handle)
        }
    }

    func savePolicyRule(_ rule: PolicyRule) throws {
        try withDatabaseHandle { handle in
            try Self.execute("PRAGMA foreign_keys = ON;", on: handle)
            try Self.execute("""
            INSERT INTO policy_rules (
                id, application_name, name, scope, matcher_json, outcome_json, priority, enabled, created_at, updated_at
            ) VALUES (
                \(quoted(rule.id)),
                \(quoted(rule.applicationName)),
                \(quoted(rule.name)),
                \(quoted(rule.scope)),
                \(quoted(rule.matcherJSON)),
                \(quoted(rule.outcomeJSON)),
                \(rule.priority),
                \(rule.enabled ? 1 : 0),
                \(quoted(Self.iso8601Formatter().string(from: rule.createdAt))),
                \(quoted(Self.iso8601Formatter().string(from: rule.updatedAt)))
            )
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                matcher_json = excluded.matcher_json,
                outcome_json = excluded.outcome_json,
                priority = excluded.priority,
                enabled = excluded.enabled,
                updated_at = excluded.updated_at;
            """, on: handle)
        }
    }

    func savePolicyApproval(_ approval: PolicyApproval) throws {
        try withDatabaseHandle { handle in
            try Self.execute("PRAGMA foreign_keys = ON;", on: handle)
            try Self.execute("""
            INSERT INTO policy_approvals (
                id, application_name, session_id, rule_id, request_type, request_payload_json, edited_payload_json, decision, actor, created_at, acted_at
            ) VALUES (
                \(quoted(approval.id)),
                \(quoted(approval.applicationName)),
                \(quoted(approval.sessionID)),
                \(quoted(approval.ruleID)),
                \(quoted(approval.requestType)),
                \(quoted(approval.requestPayloadJSON)),
                \(sqlValue(approval.editedPayloadJSON)),
                \(quoted(approval.decision)),
                \(sqlValue(approval.actor)),
                \(quoted(Self.iso8601Formatter().string(from: approval.createdAt))),
                \(sqlValue(approval.acedAt.map { Self.iso8601Formatter().string(from: $0) }))
            );
            """, on: handle)
        }
    }

    func loadPolicyApprovals(sessionID: String, applicationName: String, limit: Int) throws -> [PolicyApproval] {
        try withDatabaseHandle { handle in
            try Self.execute("PRAGMA foreign_keys = ON;", on: handle)
            let sql = """
            SELECT id, application_name, session_id, rule_id, request_type, request_payload_json, edited_payload_json, decision, actor, created_at, acted_at
            FROM policy_approvals
            WHERE application_name = \(quoted(applicationName))
              AND session_id = \(quoted(sessionID))
            ORDER BY created_at DESC
            LIMIT \(limit);
            """
            return try allPolicyApprovals(from: sql, on: handle)
        }
    }

    func logPolicyAuditEntry(_ entry: PolicyAuditLogEntry) throws {
        try withDatabaseHandle { handle in
            try Self.execute("PRAGMA foreign_keys = ON;", on: handle)
            try Self.execute("""
            INSERT INTO policy_audit_log (
                id, application_name, session_id, event_type, scope, request_json, decision, reason, actor, created_at
            ) VALUES (
                \(quoted(entry.id)),
                \(quoted(entry.applicationName)),
                \(quoted(entry.sessionID)),
                \(quoted(entry.eventType)),
                \(quoted(entry.scope)),
                \(quoted(entry.requestJSON)),
                \(quoted(entry.decision)),
                \(sqlValue(entry.reason)),
                \(sqlValue(entry.actor)),
                \(quoted(Self.iso8601Formatter().string(from: entry.createdAt)))
            );
            """, on: handle)
        }
    }

    func loadPolicyAuditLog(sessionID: String, applicationName: String, limit: Int, page: Int) throws -> [PolicyAuditLogEntry] {
        try withDatabaseHandle { handle in
            try Self.execute("PRAGMA foreign_keys = ON;", on: handle)
            let pageSize = min(max(limit, 1), 100)
            let offset = max(page - 1, 0) * pageSize
            let sql = """
            SELECT id, application_name, session_id, event_type, scope, request_json, decision, reason, actor, created_at
            FROM policy_audit_log
            WHERE application_name = \(quoted(applicationName))
              AND session_id = \(quoted(sessionID))
            ORDER BY created_at DESC
            LIMIT \(pageSize) OFFSET \(offset);
            """
            return try allPolicyAuditEntries(from: sql, on: handle)
        }
    }
}

private extension DBRepository {
    func allPolicyRules(from sql: String, on handle: OpaquePointer) throws -> [PolicyRule] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DBRepositoryError.sqliteOperationFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        var rules: [PolicyRule] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = try columnString(statement, index: 0)
            let applicationName = try columnString(statement, index: 1)
            let name = try columnString(statement, index: 2)
            let scope = try columnString(statement, index: 3)
            let matcherJSON = try columnString(statement, index: 4)
            let outcomeJSON = try columnString(statement, index: 5)
            let priority = Int(sqlite3_column_int(statement, 6))
            let enabled = sqlite3_column_int(statement, 7) != 0
            let createdAtString = try columnString(statement, index: 8)
            let updatedAtString = try columnString(statement, index: 9)

            rules.append(PolicyRule(
                id: id,
                applicationName: applicationName,
                name: name,
                scope: scope,
                matcherJSON: matcherJSON,
                outcomeJSON: outcomeJSON,
                priority: priority,
                enabled: enabled,
                createdAt: Self.iso8601Formatter().date(from: createdAtString) ?? .now,
                updatedAt: Self.iso8601Formatter().date(from: updatedAtString) ?? .now
            ))
        }
        return rules
    }

    func allPolicyApprovals(from sql: String, on handle: OpaquePointer) throws -> [PolicyApproval] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DBRepositoryError.sqliteOperationFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        var approvals: [PolicyApproval] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = try columnString(statement, index: 0)
            let applicationName = try columnString(statement, index: 1)
            let sessionID = try columnString(statement, index: 2)
            let ruleID = try columnString(statement, index: 3)
            let requestType = try columnString(statement, index: 4)
            let requestPayloadJSON = try columnString(statement, index: 5)
            let editedPayloadJSON = columnOptionalString(statement, index: 6)
            let decision = try columnString(statement, index: 7)
            let actor = columnOptionalString(statement, index: 8)
            let createdAtString = try columnString(statement, index: 9)
            let actedAtString = columnOptionalString(statement, index: 10)

            approvals.append(PolicyApproval(
                id: id,
                applicationName: applicationName,
                sessionID: sessionID,
                ruleID: ruleID,
                requestType: requestType,
                requestPayloadJSON: requestPayloadJSON,
                editedPayloadJSON: editedPayloadJSON,
                decision: decision,
                actor: actor,
                createdAt: Self.iso8601Formatter().date(from: createdAtString) ?? .now,
                acedAt: actedAtString.flatMap { Self.iso8601Formatter().date(from: $0) }
            ))
        }
        return approvals
    }

    func allPolicyAuditEntries(from sql: String, on handle: OpaquePointer) throws -> [PolicyAuditLogEntry] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DBRepositoryError.sqliteOperationFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        var entries: [PolicyAuditLogEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = try columnString(statement, index: 0)
            let applicationName = try columnString(statement, index: 1)
            let sessionID = try columnString(statement, index: 2)
            let eventType = try columnString(statement, index: 3)
            let scope = try columnString(statement, index: 4)
            let requestJSON = try columnString(statement, index: 5)
            let decision = try columnString(statement, index: 6)
            let reason = columnOptionalString(statement, index: 7)
            let actor = columnOptionalString(statement, index: 8)
            let createdAtString = try columnString(statement, index: 9)

            entries.append(PolicyAuditLogEntry(
                id: id,
                applicationName: applicationName,
                sessionID: sessionID,
                eventType: eventType,
                scope: scope,
                requestJSON: requestJSON,
                decision: decision,
                reason: reason,
                actor: actor,
                createdAt: Self.iso8601Formatter().date(from: createdAtString) ?? .now
            ))
        }
        return entries
    }
}

extension DBRepository: PolicyStore {
    public func loadRules(applicationName: String, scope: String) async throws -> [PolicyRule] {
        try loadPolicyRules(applicationName: applicationName, scope: scope)
    }

    public func saveRule(_ rule: PolicyRule) async throws {
        try savePolicyRule(rule)
    }

    public func saveApproval(_ approval: PolicyApproval) async throws {
        try savePolicyApproval(approval)
    }

    public func loadApprovals(sessionID: String, limit: Int) async throws -> [PolicyApproval] {
        try loadPolicyApprovals(sessionID: sessionID, applicationName: applicationName, limit: limit)
    }

    public func logAuditEntry(_ entry: PolicyAuditLogEntry) async throws {
        try logPolicyAuditEntry(entry)
    }

    public func auditLog(sessionID: String, limit: Int, page: Int) async throws -> [PolicyAuditLogEntry] {
        try loadPolicyAuditLog(sessionID: sessionID, applicationName: applicationName, limit: limit, page: page)
    }
}
