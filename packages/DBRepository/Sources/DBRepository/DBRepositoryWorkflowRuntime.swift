import CryptoKit
import Foundation
import ServiceContracts
import SQLite3

public struct WorkflowRunRow: Sendable, Hashable {
    public let id: String
    public var kind: String
    public var status: String
    public let contextJSON: String
    public let inputJSON: String
    public let idempotencyKey: String?
    public var currentStepID: String?
    public var resultJSON: String?
    public var errorMessage: String?
    public let createdAt: Date
    public var finishedAt: Date?

    public init(
        id: String,
        kind: String,
        status: String,
        contextJSON: String,
        inputJSON: String,
        idempotencyKey: String?,
        currentStepID: String? = nil,
        resultJSON: String? = nil,
        errorMessage: String? = nil,
        createdAt: Date,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.contextJSON = contextJSON
        self.inputJSON = inputJSON
        self.idempotencyKey = idempotencyKey
        self.currentStepID = currentStepID
        self.resultJSON = resultJSON
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.finishedAt = finishedAt
    }
}

public struct WorkflowEventRow: Sendable, Hashable {
    public let seq: Int
    public let kind: String
    public let stage: String?
    public let message: String
    public let detailJSON: String?
    public let createdAt: Date
}

public struct ToolRunRow: Sendable, Hashable {
    public let id: String
    public let toolName: String
    public let argumentsJSON: String
    public let principalJSON: String
    public let contextJSON: String
    public var status: String
    public var resultText: String?
    public var isError: Bool
    public var errorMessage: String?
    public let createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(
        id: String,
        toolName: String,
        argumentsJSON: String,
        principalJSON: String,
        contextJSON: String,
        status: String,
        resultText: String?,
        isError: Bool,
        errorMessage: String?,
        createdAt: Date,
        startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.principalJSON = principalJSON
        self.contextJSON = contextJSON
        self.status = status
        self.resultText = resultText
        self.isError = isError
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public enum WorkflowRuntimeIdempotency {
    public static func key(sessionID: String, kind: WorkflowKind, inputJSON: String) -> String {
        let material = "\(sessionID)|\(kind.rawValue)|\(inputJSON)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public extension DBRepository {
    func workflowRun(idempotencyKey: String) throws -> WorkflowRunRow? {
        try withDatabaseHandle { handle in
            let sql = """
            SELECT id, kind, status, context_json, input_json, idempotency_key,
                   current_step_id, result_json, error_message, created_at, finished_at
            FROM workflow_runs
            WHERE idempotency_key = \(quoted(idempotencyKey))
              AND status = \(quoted(WorkflowRunStatus.running.rawValue))
            LIMIT 1;
            """
            return try Self.fetchWorkflowRun(sql: sql, on: handle)
        }
    }

    func workflowRun(id: String) throws -> WorkflowRunRow? {
        try withDatabaseHandle { handle in
            let sql = """
            SELECT id, kind, status, context_json, input_json, idempotency_key,
                   current_step_id, result_json, error_message, created_at, finished_at
            FROM workflow_runs
            WHERE id = \(quoted(id))
            LIMIT 1;
            """
            return try Self.fetchWorkflowRun(sql: sql, on: handle)
        }
    }

    func insertWorkflowRun(_ row: WorkflowRunRow) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            INSERT INTO workflow_runs (
                id, kind, status, context_json, input_json, idempotency_key,
                current_step_id, result_json, error_message, created_at, finished_at
            ) VALUES (
                \(quoted(row.id)),
                \(quoted(row.kind)),
                \(quoted(row.status)),
                \(quoted(row.contextJSON)),
                \(quoted(row.inputJSON)),
                \(row.idempotencyKey.map(quoted) ?? "NULL"),
                \(row.currentStepID.map(quoted) ?? "NULL"),
                \(row.resultJSON.map(quoted) ?? "NULL"),
                \(row.errorMessage.map(quoted) ?? "NULL"),
                \(quoted(Self.iso8601Formatter().string(from: row.createdAt))),
                \(row.finishedAt.map { quoted(Self.iso8601Formatter().string(from: $0)) } ?? "NULL")
            );
            """, on: handle)
        }
    }

    func updateWorkflowRun(_ row: WorkflowRunRow) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            UPDATE workflow_runs SET
                status = \(quoted(row.status)),
                current_step_id = \(row.currentStepID.map(quoted) ?? "NULL"),
                result_json = \(row.resultJSON.map(quoted) ?? "NULL"),
                error_message = \(row.errorMessage.map(quoted) ?? "NULL"),
                finished_at = \(row.finishedAt.map { quoted(Self.iso8601Formatter().string(from: $0)) } ?? "NULL")
            WHERE id = \(quoted(row.id));
            """, on: handle)
        }
    }

    func appendWorkflowEvent(
        workflowID: String,
        kind: String,
        stage: String?,
        message: String,
        detailJSON: String? = nil
    ) throws -> Int {
        try withDatabaseHandle { handle in
            var seq = 0
            var statement: OpaquePointer?
            let nextSQL = """
            SELECT COALESCE(MAX(seq), 0) + 1 FROM workflow_run_events WHERE workflow_id = \(quoted(workflowID));
            """
            guard sqlite3_prepare_v2(handle, nextSQL, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Self.sqliteError(handle: handle, fallback: "workflow event seq")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw Self.sqliteError(handle: handle, fallback: "workflow event seq step")
            }
            seq = Int(sqlite3_column_int(statement, 0))
            let now = Self.iso8601Formatter().string(from: Date())
            try Self.execute("""
            INSERT INTO workflow_run_events (
                workflow_id, seq, kind, stage, message, detail_json, created_at
            ) VALUES (
                \(quoted(workflowID)),
                \(seq),
                \(quoted(kind)),
                \(stage.map(quoted) ?? "NULL"),
                \(quoted(message)),
                \(detailJSON.map(quoted) ?? "NULL"),
                \(quoted(now))
            );
            """, on: handle)
            return seq
        }
    }

    func workflowEvents(workflowID: String, afterSeq: Int) throws -> [WorkflowEventRow] {
        try withDatabaseHandle { handle in
            let sql = """
            SELECT seq, kind, stage, message, detail_json, created_at
            FROM workflow_run_events
            WHERE workflow_id = \(quoted(workflowID)) AND seq > \(afterSeq)
            ORDER BY seq ASC;
            """
            var rows: [WorkflowEventRow] = []
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Self.sqliteError(handle: handle, fallback: "workflow events")
            }
            defer { sqlite3_finalize(statement) }
            let formatter = Self.iso8601Formatter()
            while sqlite3_step(statement) == SQLITE_ROW {
                let seq = Int(sqlite3_column_int(statement, 0))
                guard let kindC = sqlite3_column_text(statement, 1),
                      let messageC = sqlite3_column_text(statement, 3),
                      let createdC = sqlite3_column_text(statement, 5) else { continue }
                let stage: String?
                if let stageC = sqlite3_column_text(statement, 2) {
                    stage = String(cString: stageC)
                } else {
                    stage = nil
                }
                let detail: String?
                if let detailC = sqlite3_column_text(statement, 4) {
                    detail = String(cString: detailC)
                } else {
                    detail = nil
                }
                let created = formatter.date(from: String(cString: createdC)) ?? .now
                rows.append(
                    WorkflowEventRow(
                        seq: seq,
                        kind: String(cString: kindC),
                        stage: stage,
                        message: String(cString: messageC),
                        detailJSON: detail,
                        createdAt: created
                    )
                )
            }
            return rows
        }
    }

    func insertToolRun(_ row: ToolRunRow) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            INSERT INTO tool_runs (
                id, tool_name, arguments_json, principal_json, context_json,
                status, result_text, is_error, error_message, created_at, started_at, finished_at
            ) VALUES (
                \(quoted(row.id)),
                \(quoted(row.toolName)),
                \(quoted(row.argumentsJSON)),
                \(quoted(row.principalJSON)),
                \(quoted(row.contextJSON)),
                \(quoted(row.status)),
                \(row.resultText.map(quoted) ?? "NULL"),
                \(row.isError ? 1 : 0),
                \(row.errorMessage.map(quoted) ?? "NULL"),
                \(quoted(Self.iso8601Formatter().string(from: row.createdAt))),
                \(row.startedAt.map { quoted(Self.iso8601Formatter().string(from: $0)) } ?? "NULL"),
                \(row.finishedAt.map { quoted(Self.iso8601Formatter().string(from: $0)) } ?? "NULL")
            );
            """, on: handle)
        }
    }

    func updateToolRun(_ row: ToolRunRow) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            UPDATE tool_runs SET
                status = \(quoted(row.status)),
                result_text = \(row.resultText.map(quoted) ?? "NULL"),
                is_error = \(row.isError ? 1 : 0),
                error_message = \(row.errorMessage.map(quoted) ?? "NULL"),
                started_at = \(row.startedAt.map { quoted(Self.iso8601Formatter().string(from: $0)) } ?? "NULL"),
                finished_at = \(row.finishedAt.map { quoted(Self.iso8601Formatter().string(from: $0)) } ?? "NULL")
            WHERE id = \(quoted(row.id));
            """, on: handle)
        }
    }

    func appendToolRunEvent(
        runID: String,
        kind: String,
        stage: String?,
        message: String,
        detailJSON: String? = nil
    ) throws {
        try withDatabaseHandle { handle in
            var seq = 0
            var statement: OpaquePointer?
            let nextSQL = """
            SELECT COALESCE(MAX(seq), 0) + 1 FROM tool_run_events WHERE run_id = \(quoted(runID));
            """
            guard sqlite3_prepare_v2(handle, nextSQL, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Self.sqliteError(handle: handle, fallback: "tool run event seq")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw Self.sqliteError(handle: handle, fallback: "tool run event seq step")
            }
            seq = Int(sqlite3_column_int(statement, 0))
            let now = Self.iso8601Formatter().string(from: Date())
            try Self.execute("""
            INSERT INTO tool_run_events (
                run_id, seq, kind, stage, message, detail_json, created_at
            ) VALUES (
                \(quoted(runID)),
                \(seq),
                \(quoted(kind)),
                \(stage.map(quoted) ?? "NULL"),
                \(quoted(message)),
                \(detailJSON.map(quoted) ?? "NULL"),
                \(quoted(now))
            );
            """, on: handle)
        }
    }

    private static func fetchWorkflowRun(sql: String, on handle: OpaquePointer) throws -> WorkflowRunRow? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError(handle: handle, fallback: "workflow run fetch")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let idC = sqlite3_column_text(statement, 0),
              let kindC = sqlite3_column_text(statement, 1),
              let statusC = sqlite3_column_text(statement, 2),
              let contextC = sqlite3_column_text(statement, 3),
              let inputC = sqlite3_column_text(statement, 4),
              let createdC = sqlite3_column_text(statement, 9)
        else { return nil }
        let idempotency: String?
        if let idemC = sqlite3_column_text(statement, 5) {
            idempotency = String(cString: idemC)
        } else {
            idempotency = nil
        }
        let currentStep: String?
        if let stepC = sqlite3_column_text(statement, 6) {
            currentStep = String(cString: stepC)
        } else {
            currentStep = nil
        }
        let result: String?
        if let resultC = sqlite3_column_text(statement, 7) {
            result = String(cString: resultC)
        } else {
            result = nil
        }
        let error: String?
        if let errorC = sqlite3_column_text(statement, 8) {
            error = String(cString: errorC)
        } else {
            error = nil
        }
        let finished: Date?
        if let finishedC = sqlite3_column_text(statement, 10) {
            finished = iso8601Formatter().date(from: String(cString: finishedC))
        } else {
            finished = nil
        }
        let created = iso8601Formatter().date(from: String(cString: createdC)) ?? .now
        return WorkflowRunRow(
            id: String(cString: idC),
            kind: String(cString: kindC),
            status: String(cString: statusC),
            contextJSON: String(cString: contextC),
            inputJSON: String(cString: inputC),
            idempotencyKey: idempotency,
            currentStepID: currentStep,
            resultJSON: result,
            errorMessage: error,
            createdAt: created,
            finishedAt: finished
        )
    }
}
