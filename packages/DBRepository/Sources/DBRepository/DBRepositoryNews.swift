import Foundation
import SQLite3
import Structure

public extension DBRepository {
    func upsertNewsReader(_ spec: NewsReaderSpec) throws {
        let topicsData = try JSONEncoder().encode(spec.topics)
        let sourcesData = try JSONEncoder().encode(spec.sources)
        let topics = String(data: topicsData, encoding: .utf8) ?? "[]"
        let sources = String(data: sourcesData, encoding: .utf8) ?? "[]"
        try withDatabaseHandle { handle in
            try Self.execute("""
            INSERT INTO news_readers (
                id, name, topics_json, sources_json, mode, max_count, schedule,
                summary_text, last_error, last_fetched_at, created_at, updated_at
            ) VALUES (
                \(quoted(spec.id)),
                \(quoted(spec.name)),
                \(quoted(topics)),
                \(quoted(sources)),
                \(quoted(spec.mode.rawValue)),
                \(spec.maxCount),
                \(quoted(spec.schedule.rawValue)),
                \(sqlValue(spec.summaryText)),
                \(sqlValue(spec.lastError)),
                \(sqlValue(spec.lastFetchedAt.map { Self.iso8601Formatter().string(from: $0) })),
                \(quoted(Self.iso8601Formatter().string(from: spec.createdAt))),
                \(quoted(Self.iso8601Formatter().string(from: spec.updatedAt)))
            )
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                topics_json = excluded.topics_json,
                sources_json = excluded.sources_json,
                mode = excluded.mode,
                max_count = excluded.max_count,
                schedule = excluded.schedule,
                summary_text = excluded.summary_text,
                last_error = excluded.last_error,
                last_fetched_at = excluded.last_fetched_at,
                updated_at = excluded.updated_at;
            """, on: handle)
        }
    }

    func listNewsReaders() throws -> [NewsReaderSpec] {
        try withDatabaseHandle { handle in
            let sql = """
            SELECT id, name, topics_json, sources_json, mode, max_count, schedule,
                   summary_text, last_error, last_fetched_at, created_at, updated_at
            FROM news_readers
            ORDER BY updated_at DESC;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Self.sqliteError(handle: handle, fallback: "Failed to list news readers.")
            }
            defer { sqlite3_finalize(statement) }
            var rows: [NewsReaderSpec] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(try decodeNewsReader(statement: statement))
            }
            return rows
        }
    }

    func deleteNewsReader(id: String) throws {
        try withDatabaseHandle { handle in
            try Self.execute("DELETE FROM news_readers WHERE id = \(quoted(id));", on: handle)
        }
    }

    func replaceNewsItems(readerID: String, items: [NewsItem]) throws {
        try withDatabaseHandle { handle in
            try Self.withImmediateTransaction(on: handle) {
                try Self.execute("DELETE FROM news_items WHERE reader_id = \(quoted(readerID));", on: handle)
                for item in items {
                    try Self.execute("""
                    INSERT INTO news_items (
                        id, reader_id, title, source_url, source_label, summary, published_at, fetched_at
                    ) VALUES (
                        \(quoted(item.id)),
                        \(quoted(item.readerID)),
                        \(quoted(item.title)),
                        \(quoted(item.sourceURL)),
                        \(quoted(item.sourceLabel)),
                        \(sqlValue(item.summary)),
                        \(sqlValue(item.publishedAt.map { Self.iso8601Formatter().string(from: $0) })),
                        \(quoted(Self.iso8601Formatter().string(from: item.fetchedAt)))
                    );
                    """, on: handle)
                }
            }
        }
    }

    func listNewsItems(readerID: String) throws -> [NewsItem] {
        try withDatabaseHandle { handle in
            let sql = """
            SELECT id, reader_id, title, source_url, source_label, summary, published_at, fetched_at
            FROM news_items
            WHERE reader_id = \(quoted(readerID))
            ORDER BY COALESCE(published_at, fetched_at) DESC;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Self.sqliteError(handle: handle, fallback: "Failed to list news items.")
            }
            defer { sqlite3_finalize(statement) }
            var rows: [NewsItem] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(try decodeNewsItem(statement: statement))
            }
            return rows
        }
    }

    private func decodeNewsReader(statement: OpaquePointer) throws -> NewsReaderSpec {
        func text(_ index: Int32) -> String {
            String(cString: sqlite3_column_text(statement, index))
        }
        func optionalText(_ index: Int32) -> String? {
            sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : text(index)
        }
        let topics = (try? JSONDecoder().decode([String].self, from: Data(text(2).utf8))) ?? []
        let sources = (try? JSONDecoder().decode([NewsSource].self, from: Data(text(3).utf8))) ?? []
        return NewsReaderSpec(
            id: text(0),
            name: text(1),
            topics: topics,
            sources: sources,
            mode: NewsReaderMode(rawValue: text(4)) ?? .rss,
            maxCount: Int(sqlite3_column_int(statement, 5)),
            schedule: NewsReaderSchedule(rawValue: text(6)) ?? .off,
            summaryText: optionalText(7),
            lastError: optionalText(8),
            lastFetchedAt: optionalText(9).flatMap { Self.iso8601Formatter().date(from: $0) },
            createdAt: Self.iso8601Formatter().date(from: text(10)) ?? .now,
            updatedAt: Self.iso8601Formatter().date(from: text(11)) ?? .now
        )
    }

    private func decodeNewsItem(statement: OpaquePointer) throws -> NewsItem {
        func text(_ index: Int32) -> String {
            String(cString: sqlite3_column_text(statement, index))
        }
        func optionalText(_ index: Int32) -> String? {
            sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : text(index)
        }
        return NewsItem(
            id: text(0),
            readerID: text(1),
            title: text(2),
            sourceURL: text(3),
            sourceLabel: text(4),
            summary: optionalText(5),
            publishedAt: optionalText(6).flatMap { Self.iso8601Formatter().date(from: $0) },
            fetchedAt: Self.iso8601Formatter().date(from: text(7)) ?? .now
        )
    }
}
