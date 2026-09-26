import SQLite3
import Structure
import XCTest
@testable import DBRepository

/// Inserts one row into every table from the migrated schema and reads every column back.
final class SchemaColumnRoundTripTests: XCTestCase {
    func testEveryMigratedColumnRoundTrips() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = DBRepository(
            configuration: DBRepositoryConfiguration(
                applicationName: "ui",
                databaseName: "derrick",
                databaseDirectoryURL: directory,
                username: "app-user",
                password: "app-secret"
            )
        )
        let url = try await repository.createEmptyDatabaseIfNeeded(
            username: "app-user",
            password: "app-secret"
        )

        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            XCTFail("Unable to open \(url.path)")
            return
        }
        defer { sqlite3_close(handle) }
        try exec("PRAGMA foreign_keys = ON;", on: handle)

        let tables = try tableNames(on: handle)
        XCTAssertFalse(tables.isEmpty)
        var pending = tables
        var guardCount = 0
        while !pending.isEmpty {
            guardCount += 1
            XCTAssertLessThan(guardCount, tables.count + 2, "Could not insert \(pending)")
            var next: [String] = []
            var insertedAny = false
            for table in pending {
                do {
                    try insertAndReadBack(table: table, on: handle)
                    insertedAny = true
                } catch {
                    let message = String(describing: error)
                    if message.contains("FOREIGN KEY") {
                        next.append(table)
                    } else {
                        XCTFail("\(table): \(message)")
                        return
                    }
                }
            }
            if !insertedAny {
                XCTFail("Foreign key cycle or missing parent for \(next)")
                return
            }
            pending = next
        }
    }

    private func insertAndReadBack(table: String, on handle: OpaquePointer) throws {
        let columns = try columnInfo(table: table, on: handle)
        XCTAssertFalse(columns.isEmpty, table)
        let names = columns.map(\.name)
        let values = columns.map { literal(for: $0, table: table) }
        let quotedNames = names.map(quoteIdentifier).joined(separator: ", ")
        let sql = "INSERT INTO \(quoteIdentifier(table)) (\(quotedNames)) VALUES (\(values.joined(separator: ", ")));"
        try exec(sql, on: handle)

        var statement: OpaquePointer?
        let select = "SELECT \(quotedNames) FROM \(quoteIdentifier(table)) LIMIT 1;"
        guard sqlite3_prepare_v2(handle, select, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SchemaRoundTripError.message("prepare select \(table)")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SchemaRoundTripError.message("no row \(table)")
        }
        for (index, column) in columns.enumerated() {
            let stored = read(statement, index: Int32(index), type: column.type)
            let expected = expectedReadback(for: column, table: table)
            XCTAssertEqual(stored, expected, "\(table).\(column.name)")
        }
    }

    private func literal(for column: Column, table: String) -> String {
        switch affinity(column.type) {
        case .integer:
            return "\(integerValue(for: column, table: table))"
        case .real:
            return "1.25"
        case .text:
            return "'\(textValue(for: column, table: table).replacingOccurrences(of: "'", with: "''"))'"
        }
    }

    private func expectedReadback(for column: Column, table: String) -> String {
        switch affinity(column.type) {
        case .integer:
            return "\(integerValue(for: column, table: table))"
        case .real:
            return "1.25"
        case .text:
            return textValue(for: column, table: table)
        }
    }

    private func integerValue(for column: Column, table: String) -> Int {
        if column.primaryKey { return 1 }
        return 7
    }

    private func textValue(for column: Column, table: String) -> String {
        switch column.name {
        case "application_name":
            return "ui"
        case "session_id":
            return "s1"
        case "agent_id":
            return "a1"
        case "plugin_id":
            return "plugin-1"
        case "version":
            return "1.0.0"
        case "thread_id":
            return "id-messaging_threads"
        case "job_id":
            return "id-jobs"
        case "workflow_id":
            return "id-workflow_runs"
        case "run_id":
            return "id-tool_runs"
        case "id":
            return "id-\(table)"
        default:
            return "\(table).\(column.name)"
        }
    }

    private func tableNames(on handle: OpaquePointer) throws -> [String] {
        var statement: OpaquePointer?
        let sql = """
        SELECT name FROM sqlite_master
        WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
        ORDER BY name ASC;
        """
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SchemaRoundTripError.message("list tables")
        }
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let c = sqlite3_column_text(statement, 0) {
                names.append(String(cString: c))
            }
        }
        return names
    }

    private func columnInfo(table: String, on handle: OpaquePointer) throws -> [Column] {
        var statement: OpaquePointer?
        let sql = "PRAGMA table_info(\(quoteIdentifier(table)));"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SchemaRoundTripError.message("table_info \(table)")
        }
        defer { sqlite3_finalize(statement) }
        var columns: [Column] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let nameC = sqlite3_column_text(statement, 1),
                  let typeC = sqlite3_column_text(statement, 2) else { continue }
            columns.append(
                Column(
                    name: String(cString: nameC),
                    type: String(cString: typeC),
                    primaryKey: sqlite3_column_int(statement, 5) != 0
                )
            )
        }
        return columns
    }

    private func read(_ statement: OpaquePointer, index: Int32, type: String) -> String {
        switch affinity(type) {
        case .integer:
            return "\(sqlite3_column_int(statement, index))"
        case .real:
            return "\(sqlite3_column_double(statement, index))"
        case .text:
            guard let c = sqlite3_column_text(statement, index) else { return "" }
            return String(cString: c)
        }
    }

    private func affinity(_ declared: String) -> Affinity {
        let upper = declared.uppercased()
        if upper.contains("INT") { return .integer }
        if upper.contains("REAL") || upper.contains("FLOA") || upper.contains("DOUB") { return .real }
        return .text
    }

    private func quoteIdentifier(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func exec(_ sql: String, on handle: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "sqlite exec failed"
            sqlite3_free(error)
            throw SchemaRoundTripError.message(message)
        }
    }

    private struct Column {
        let name: String
        let type: String
        let primaryKey: Bool
    }

    private enum Affinity {
        case integer
        case real
        case text
    }

    private enum SchemaRoundTripError: Error, CustomStringConvertible {
        case message(String)
        var description: String { if case .message(let message) = self { return message } else { return "" } }
    }
}
