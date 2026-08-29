import Foundation
import SQLite3

extension DBRepository {
    /// Single entry point for opening the shared SQLite file.
    /// All UI / AgentService / future services go through this — no ad-hoc opens outside DBRepository.
    func withDatabaseHandle<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        // FULLMUTEX: serialized use of this connection if ever shared across threads.
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let message = String(cString: sqlite3_errstr(status))
            if let handle {
                sqlite3_close(handle)
            }
            throw DBRepositoryError.sqliteOpenFailed(message)
        }

        defer {
            // Prefer close_v2 so a busy WAL checkpoint cannot fail the close path.
            _ = sqlite3_close_v2(handle)
        }

        try Self.configureConnectionForMultiProcessAccess(on: handle)
        return try body(handle)
    }

    /// One writer at a time across UI and derrickd. Rolls back on any throw.
    static func withImmediateTransaction<T>(
        on handle: OpaquePointer,
        _ body: () throws -> T
    ) throws -> T {
        try execute("BEGIN IMMEDIATE;", on: handle)
        do {
            let value = try body()
            try execute("COMMIT;", on: handle)
            return value
        } catch {
            try? execute("ROLLBACK;", on: handle)
            throw error
        }
    }

    /// Safe defaults for multi-process access (UI + AgentService + JobService, etc.).
    /// - WAL: concurrent readers + one writer without blocking the whole DB.
    /// - busy_timeout: wait for locks instead of failing with "database is locked".
    /// - synchronous=NORMAL: durable enough with WAL; better multi-process write throughput.
    /// - foreign_keys: enforce referential integrity on every connection.
    static func configureConnectionForMultiProcessAccess(on handle: OpaquePointer) throws {
        try execute("PRAGMA foreign_keys = ON;", on: handle)
        // Milliseconds. Covers bootstrap races and multi-agent memory/policy writes.
        try execute("PRAGMA busy_timeout = 5000;", on: handle)
        // Persistent on the DB file once set; re-applied so every connection is WAL-aware.
        try execute("PRAGMA journal_mode = WAL;", on: handle)
        try execute("PRAGMA synchronous = NORMAL;", on: handle)
    }

    static func execute(_ sql: String, on handle: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        let status = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard status == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errstr(status))
            sqlite3_free(errorMessage)
            throw DBRepositoryError.sqliteOperationFailed(message)
        }
    }

    static func sqliteError(handle: OpaquePointer, fallback: String) -> DBRepositoryError {
        let message = String(cString: sqlite3_errmsg(handle))
        if message.isEmpty {
            return .sqliteOperationFailed(fallback)
        }
        return .sqliteOperationFailed(message)
    }
}
