import Foundation
import Plugin
import Structure
import SQLite3

public extension DBRepository {
    func upsertMessagingConnector(_ connector: MessagingConnectorDTO) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            INSERT INTO messaging_connectors (
                plugin_id, display_name, listening, created_at, updated_at
            ) VALUES (
                \(quoted(connector.pluginID)),
                \(quoted(connector.displayName)),
                \(connector.listening ? 1 : 0),
                \(quoted(Self.iso8601Formatter().string(from: connector.createdAt))),
                \(quoted(Self.iso8601Formatter().string(from: connector.updatedAt)))
            )
            ON CONFLICT(plugin_id) DO UPDATE SET
                display_name = excluded.display_name,
                updated_at = excluded.updated_at;
            """, on: handle)
        }
    }

    func listMessagingConnectors(listeningOnly: Bool = false) throws -> [MessagingConnectorDTO] {
        let rows = try withDatabaseHandle { handle in
            let sql = """
            SELECT c.plugin_id, c.display_name, c.listening, c.created_at, c.updated_at,
                   c.listening_since,
                   COALESCE(SUM(t.unread_count), 0)
            FROM messaging_connectors c
            LEFT JOIN messaging_threads t ON t.plugin_id = c.plugin_id
            GROUP BY c.plugin_id
            ORDER BY c.display_name ASC, c.plugin_id ASC;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Self.sqliteError(handle: handle, fallback: "Failed to prepare messaging connector list.")
            }
            defer { sqlite3_finalize(statement) }
            var rows: [MessagingConnectorDTO] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(try decodeMessagingConnector(statement: statement))
            }
            return rows
        }
        guard listeningOnly else { return rows }
        return rows.filter(\.listening)
    }

    /// Drops connector rows (and cascaded threads/messages) not in `pluginIDs`.
    func pruneMessagingConnectors(keeping pluginIDs: Set<String>) throws {
        try withDatabaseHandle { handle in
            if pluginIDs.isEmpty {
                try Self.execute("DELETE FROM messaging_connectors;", on: handle)
                return
            }
            let quotedIDs = pluginIDs.map { quoted($0) }.joined(separator: ", ")
            try Self.execute("""
            DELETE FROM messaging_connectors
            WHERE plugin_id NOT IN (\(quotedIDs));
            """, on: handle)
        }
    }

    func setMessagingConnectorListening(pluginID: String, listening: Bool) throws {
        let trimmed = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DBRepositoryError.sqliteOperationFailed("Messaging connector id is required.")
        }
        try withDatabaseHandle { handle in
            try requireMessagingConnector(pluginID: trimmed, on: handle)
            let updated = Self.iso8601Formatter().string(from: Date())
            let listeningSinceSQL: String
            if listening {
                listeningSinceSQL = quoted(updated)
            } else {
                listeningSinceSQL = "NULL"
            }
            try Self.execute("""
            UPDATE messaging_connectors
            SET listening = \(listening ? 1 : 0),
                updated_at = \(quoted(updated)),
                listening_since = \(listeningSinceSQL)
            WHERE plugin_id = \(quoted(trimmed));
            """, on: handle)
        }
    }

    /// Creates a thread if needed. Never overwrites mute or unread on conflict.
    func upsertMessagingThread(_ thread: MessagingThreadDTO) throws {
        try withDatabaseHandle { handle in
            try requireMessagingConnector(pluginID: thread.pluginID, on: handle)
            try ensureMessagingThread(thread, on: handle)
        }
    }

    func listMessagingThreads(pluginID: String) throws -> [MessagingThreadDTO] {
        try withDatabaseHandle { handle in
            try loadMessagingThreads(pluginID: pluginID, on: handle)
        }
    }

    func messagingThread(id: String) throws -> MessagingThreadDTO? {
        try withDatabaseHandle { handle in
            try loadMessagingThread(id: id, on: handle)
        }
    }

    /// Drops thread rows (and cascaded messages) for a connector that are not in `vendorThreadIDs`.
    func pruneMessagingThreads(pluginID: String, keepingVendorThreadIDs: Set<String>) throws {
        let trimmed = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DBRepositoryError.sqliteOperationFailed("Messaging connector id is required.")
        }
        try withDatabaseHandle { handle in
            if keepingVendorThreadIDs.isEmpty {
                try Self.execute("""
                DELETE FROM messaging_threads
                WHERE plugin_id = \(quoted(trimmed));
                """, on: handle)
                return
            }
            let quotedIDs = keepingVendorThreadIDs.map { quoted($0) }.joined(separator: ", ")
            try Self.execute("""
            DELETE FROM messaging_threads
            WHERE plugin_id = \(quoted(trimmed))
              AND vendor_thread_id NOT IN (\(quotedIDs));
            """, on: handle)
        }
    }

    func setMessagingThreadMuted(id: String, muted: Bool) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            UPDATE messaging_threads
            SET muted = \(muted ? 1 : 0)
            WHERE id = \(quoted(id));
            """, on: handle)
        }
    }

    func setMessagingThreadDefaultAgentProfile(threadID: String, handle: String?) throws {
        let trimmedID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw DBRepositoryError.sqliteOperationFailed("Messaging thread id is required.")
        }
        let normalized = handle?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let valueSQL: String
        if let normalized, !normalized.isEmpty {
            guard AgentProfileHandle.isValid(normalized) else {
                throw DBRepositoryError.sqliteOperationFailed("Invalid agent profile handle.")
            }
            valueSQL = quoted(normalized)
        } else {
            valueSQL = "NULL"
        }
        try withDatabaseHandle { handle in
            try Self.execute("""
            UPDATE messaging_threads
            SET default_agent_profile_handle = \(valueSQL)
            WHERE id = \(quoted(trimmedID));
            """, on: handle)
        }
    }

    func clearMessagingThreadUnread(id: String) throws {
        try withDatabaseHandle { handle in
            try Self.execute("""
            UPDATE messaging_threads
            SET unread_count = 0
            WHERE id = \(quoted(id));
            """, on: handle)
        }
    }

    /// Removes automated test messages that were accidentally persisted in a live database.
    func purgeMessagingMessages(withBodyPrefix prefix: String) throws -> Int {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return try withDatabaseHandle { handle in
            try Self.execute("""
            DELETE FROM messaging_messages
            WHERE body LIKE \(quoted(trimmed + "%"));
            """, on: handle)
            return Int(sqlite3_changes(handle))
        }
    }

    /// Newest-first page, then reverse for chat-style display (oldest of the window first).
    func listMessagingMessages(
        threadID: String,
        before: MessagingMessageCursor? = nil,
        limit: Int = MessagingViewport.maxVisibleMessages,
        filter: MessagingMessageListFilter = .channelRoots
    ) throws -> [MessagingMessageDTO] {
        let pageSize = max(1, min(limit, MessagingViewport.maxVisibleMessages))
        return try withDatabaseHandle { handle in
            var clauses = ["thread_id = \(quoted(threadID))"]
            switch filter {
            case .channelRoots:
                clauses.append("(parent_vendor_message_id IS NULL OR parent_vendor_message_id = '')")
            case .replyThread(let parentID):
                let parent = quoted(parentID.trimmingCharacters(in: .whitespacesAndNewlines))
                clauses.append("(vendor_message_id = \(parent) OR parent_vendor_message_id = \(parent))")
            }
            if let before {
                let time = quoted(Self.iso8601Formatter().string(from: before.createdAt))
                let id = quoted(before.id)
                clauses.append("(created_at < \(time) OR (created_at = \(time) AND id < \(id)))")
            }
            let sql = """
            SELECT id, thread_id, vendor_message_id, direction, sender, body, created_at,
                   parent_vendor_message_id, reply_count
            FROM messaging_messages
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY created_at DESC, id DESC
            LIMIT \(pageSize);
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Self.sqliteError(handle: handle, fallback: "Failed to prepare messaging message list.")
            }
            defer { sqlite3_finalize(statement) }
            var rows: [MessagingMessageDTO] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(try decodeMessagingMessage(statement: statement))
            }
            return rows.reversed()
        }
    }

    /// Inbound messages that have not yet been claimed for an agent turn.
    func listUnclaimedInboundMessagingMessages(limit: Int = 40) throws -> [MessagingPersistResult] {
        let pageSize = max(1, min(limit, 80))
        return try withDatabaseHandle { handle in
            let sql = """
            SELECT
                m.id, m.thread_id, m.vendor_message_id, m.direction, m.sender, m.body, m.created_at,
                m.parent_vendor_message_id, m.reply_count,
                t.id, t.plugin_id, t.vendor_thread_id, t.title, t.last_activity_at, t.muted,
                t.unread_count, t.created_at
            FROM messaging_messages m
            INNER JOIN messaging_threads t ON t.id = m.thread_id
            LEFT JOIN messaging_agent_handled h
              ON h.plugin_id = t.plugin_id
             AND h.vendor_message_id = m.vendor_message_id
            WHERE m.direction = \(quoted(MessagingMessageDirection.inbound.rawValue))
              AND m.vendor_message_id IS NOT NULL
              AND TRIM(m.vendor_message_id) != ''
              AND h.plugin_id IS NULL
            ORDER BY m.created_at DESC, m.id DESC
            LIMIT \(pageSize);
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Self.sqliteError(handle: handle, fallback: "Failed to prepare unclaimed inbound messaging list.")
            }
            defer { sqlite3_finalize(statement) }
            var rows: [MessagingPersistResult] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let message = try decodeMessagingMessage(statement: statement)
                let thread = MessagingThreadDTO(
                    id: try columnString(statement, index: 9),
                    pluginID: try columnString(statement, index: 10),
                    vendorThreadID: try columnString(statement, index: 11),
                    title: try columnString(statement, index: 12),
                    lastActivityAt: Self.iso8601Formatter().date(from: try columnString(statement, index: 13)) ?? .now,
                    muted: sqlite3_column_int(statement, 14) != 0,
                    unreadCount: Int(sqlite3_column_int(statement, 15)),
                    createdAt: Self.iso8601Formatter().date(from: try columnString(statement, index: 16)) ?? .now
                )
                rows.append(MessagingPersistResult(inserted: true, message: message, thread: thread))
            }
            return rows
        }
    }

    /// Latest reply body for each parent, for the channel "N replies" row.
    func latestReplyPreviews(
        threadID: String,
        parentVendorMessageIDs: [String]
    ) throws -> [String: String] {
        let unique = Array(
            Set(
                parentVendorMessageIDs
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        )
        let parents = Array(unique.prefix(MessagingViewport.maxVisibleMessages))
        guard !parents.isEmpty else { return [:] }
        let list = parents.map { quoted($0) }.joined(separator: ", ")
        return try withDatabaseHandle { handle in
            let sql = """
            SELECT parent_vendor_message_id, body
            FROM messaging_messages
            WHERE thread_id = \(quoted(threadID))
              AND parent_vendor_message_id IN (\(list))
            ORDER BY created_at DESC, id DESC;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Self.sqliteError(handle: handle, fallback: "Failed to prepare reply preview list.")
            }
            defer { sqlite3_finalize(statement) }
            var previews: [String: String] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                let parent = columnOptionalString(statement, index: 0) ?? ""
                guard !parent.isEmpty, previews[parent] == nil else { continue }
                previews[parent] = columnOptionalString(statement, index: 1) ?? ""
            }
            return previews
        }
    }

    /// Ingress write path. One IMMEDIATE transaction: ensure thread, insert-or-ignore
    /// by vendor id, bump unread only for a new row on an unmuted thread.
    func persistMessagingInbound(_ record: MessagingInboundRecord) throws -> MessagingPersistResult {
        let vendorMessageID = record.vendorMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !vendorMessageID.isEmpty else {
            throw DBRepositoryError.sqliteOperationFailed("Inbound messages need a vendor message id.")
        }
        let pluginID = record.pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        let vendorThreadID = record.vendorThreadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pluginID.isEmpty, !vendorThreadID.isEmpty else {
            throw DBRepositoryError.sqliteOperationFailed("Inbound messages need a plugin id and vendor thread id.")
        }

        return try withDatabaseHandle { handle in
            try Self.withImmediateTransaction(on: handle) {
                try requireMessagingConnector(pluginID: pluginID, on: handle)
                let seed = MessagingThreadDTO(
                    pluginID: pluginID,
                    vendorThreadID: vendorThreadID,
                    title: record.threadTitle,
                    lastActivityAt: record.createdAt
                )
                try ensureMessagingThread(seed, on: handle)
                guard var thread = try loadMessagingThread(
                    pluginID: pluginID,
                    vendorThreadID: vendorThreadID,
                    on: handle
                ) else {
                    throw DBRepositoryError.sqliteOperationFailed("Failed to load messaging thread after upsert.")
                }

                let candidate = MessagingMessageDTO(
                    threadID: thread.id,
                    vendorMessageID: vendorMessageID,
                    direction: .inbound,
                    sender: record.sender,
                    body: record.body,
                    createdAt: record.createdAt,
                    parentVendorMessageID: record.parentVendorMessageID,
                    replyCount: record.replyCount
                )
                let insert = try insertMessagingMessageLocked(
                    candidate,
                    on: handle
                )
                if insert.inserted {
                    let created = Self.iso8601Formatter().string(from: record.createdAt)
                    let bumpUnread = record.countAsUnread && !thread.muted
                    try Self.execute("""
                    UPDATE messaging_threads
                    SET last_activity_at = MAX(last_activity_at, \(quoted(created))),
                        unread_count = unread_count + \(bumpUnread ? 1 : 0)
                    WHERE id = \(quoted(thread.id));
                    """, on: handle)
                    if let reloaded = try loadMessagingThread(id: thread.id, on: handle) {
                        thread = reloaded
                    }
                }
                return MessagingPersistResult(
                    inserted: insert.inserted,
                    message: insert.message,
                    thread: thread
                )
            }
        }
    }

    func insertMessagingMessage(
        _ message: MessagingMessageDTO,
        incrementUnread: Bool
    ) throws -> MessagingMessageInsertResult {
        try withDatabaseHandle { handle in
            try Self.withImmediateTransaction(on: handle) {
                let insert = try insertMessagingMessageLocked(message, on: handle)
                if insert.inserted {
                    let created = Self.iso8601Formatter().string(from: message.createdAt)
                    try Self.execute("""
                    UPDATE messaging_threads
                    SET last_activity_at = MAX(last_activity_at, \(quoted(created))),
                        unread_count = unread_count + \(incrementUnread ? 1 : 0)
                    WHERE id = \(quoted(message.threadID));
                    """, on: handle)
                }
                return insert
            }
        }
    }

    private func ensureMessagingThread(_ thread: MessagingThreadDTO, on handle: OpaquePointer) throws {
        let activity = Self.iso8601Formatter().string(from: thread.lastActivityAt)
        let created = Self.iso8601Formatter().string(from: thread.createdAt)
        try Self.execute("""
        INSERT INTO messaging_threads (
            id, plugin_id, vendor_thread_id, title, last_activity_at,
            muted, unread_count, default_agent_profile_handle, created_at
        ) VALUES (
            \(quoted(thread.id)),
            \(quoted(thread.pluginID)),
            \(quoted(thread.vendorThreadID)),
            \(quoted(thread.title)),
            \(quoted(activity)),
            \(thread.muted ? 1 : 0),
            \(max(0, thread.unreadCount)),
            \(sqlValue(thread.defaultAgentProfileHandle)),
            \(quoted(created))
        )
        ON CONFLICT(plugin_id, vendor_thread_id) DO UPDATE SET
            title = excluded.title,
            last_activity_at = MAX(messaging_threads.last_activity_at, excluded.last_activity_at);
        """, on: handle)
    }

    private func insertMessagingMessageLocked(
        _ message: MessagingMessageDTO,
        on handle: OpaquePointer
    ) throws -> MessagingMessageInsertResult {
        let created = Self.iso8601Formatter().string(from: message.createdAt)
        try Self.execute("""
        INSERT OR IGNORE INTO messaging_messages (
            id, thread_id, vendor_message_id, direction, sender, body, created_at,
            parent_vendor_message_id, reply_count
        ) VALUES (
            \(quoted(message.id)),
            \(quoted(message.threadID)),
            \(sqlValue(message.vendorMessageID)),
            \(quoted(message.direction.rawValue)),
            \(quoted(message.sender)),
            \(quoted(message.body)),
            \(quoted(created)),
            \(sqlValue(message.parentVendorMessageID)),
            \(max(0, message.replyCount))
        );
        """, on: handle)

        if sqlite3_changes(handle) > 0 {
            try refreshReplyCountLocked(
                threadID: message.threadID,
                parentVendorMessageID: message.parentVendorMessageID,
                on: handle
            )
            let stored = try loadMessagingMessage(id: message.id, on: handle) ?? message
            return MessagingMessageInsertResult(inserted: true, message: stored)
        }

        if let vendorID = message.vendorMessageID, !vendorID.isEmpty,
           let existing = try loadMessagingMessage(
            threadID: message.threadID,
            vendorMessageID: vendorID,
            on: handle
           ) {
            let merged = try mergeMessagingMessageMetadataLocked(
                existing: existing,
                incoming: message,
                on: handle
            )
            try refreshReplyCountLocked(
                threadID: message.threadID,
                parentVendorMessageID: merged.parentVendorMessageID,
                on: handle
            )
            return MessagingMessageInsertResult(inserted: false, message: merged)
        }
        if let existing = try loadMessagingMessage(id: message.id, on: handle) {
            let merged = try mergeMessagingMessageMetadataLocked(
                existing: existing,
                incoming: message,
                on: handle
            )
            return MessagingMessageInsertResult(inserted: false, message: merged)
        }
        throw DBRepositoryError.sqliteOperationFailed("Messaging insert was ignored but the row was not found.")
    }

    private func mergeMessagingMessageMetadataLocked(
        existing: MessagingMessageDTO,
        incoming: MessagingMessageDTO,
        on handle: OpaquePointer
    ) throws -> MessagingMessageDTO {
        let parentSQL = incoming.parentVendorMessageID.map { sqlValue($0) } ?? "parent_vendor_message_id"
        try Self.execute("""
        UPDATE messaging_messages
        SET parent_vendor_message_id = \(parentSQL),
            reply_count = MAX(reply_count, \(max(0, incoming.replyCount)))
        WHERE id = \(quoted(existing.id));
        """, on: handle)
        return try loadMessagingMessage(id: existing.id, on: handle) ?? existing
    }

    private func refreshReplyCountLocked(
        threadID: String,
        parentVendorMessageID: String?,
        on handle: OpaquePointer
    ) throws {
        guard let parentVendorMessageID, !parentVendorMessageID.isEmpty else { return }
        let countSQL = """
        SELECT COUNT(*)
        FROM messaging_messages
        WHERE thread_id = \(quoted(threadID))
          AND parent_vendor_message_id = \(quoted(parentVendorMessageID));
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, countSQL, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Self.sqliteError(handle: handle, fallback: "Failed to count messaging replies.")
        }
        defer { sqlite3_finalize(statement) }
        let counted = sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
        try Self.execute("""
        UPDATE messaging_messages
        SET reply_count = MAX(reply_count, \(counted))
        WHERE thread_id = \(quoted(threadID))
          AND vendor_message_id = \(quoted(parentVendorMessageID));
        """, on: handle)
    }

    private func requireMessagingConnector(pluginID: String, on handle: OpaquePointer) throws {
        let sql = """
        SELECT 1 FROM messaging_connectors WHERE plugin_id = \(quoted(pluginID)) LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Self.sqliteError(handle: handle, fallback: "Failed to look up messaging connector.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DBRepositoryError.sqliteOperationFailed(
                "Messaging connector '\(pluginID)' is not registered."
            )
        }
    }

    private func loadMessagingThreads(pluginID: String, on handle: OpaquePointer) throws -> [MessagingThreadDTO] {
        let sql = """
        SELECT id, plugin_id, vendor_thread_id, title, last_activity_at,
               muted, unread_count, created_at, default_agent_profile_handle
        FROM messaging_threads
        WHERE plugin_id = \(quoted(pluginID))
        ORDER BY last_activity_at DESC, id DESC;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Self.sqliteError(handle: handle, fallback: "Failed to prepare messaging thread list.")
        }
        defer { sqlite3_finalize(statement) }
        var rows: [MessagingThreadDTO] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(try decodeMessagingThread(statement: statement))
        }
        return rows
    }

    private func loadMessagingThread(id: String, on handle: OpaquePointer) throws -> MessagingThreadDTO? {
        let sql = """
        SELECT id, plugin_id, vendor_thread_id, title, last_activity_at,
               muted, unread_count, created_at, default_agent_profile_handle
        FROM messaging_threads
        WHERE id = \(quoted(id))
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Self.sqliteError(handle: handle, fallback: "Failed to prepare messaging thread lookup.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try decodeMessagingThread(statement: statement)
    }

    private func loadMessagingThread(
        pluginID: String,
        vendorThreadID: String,
        on handle: OpaquePointer
    ) throws -> MessagingThreadDTO? {
        let sql = """
        SELECT id, plugin_id, vendor_thread_id, title, last_activity_at,
               muted, unread_count, created_at, default_agent_profile_handle
        FROM messaging_threads
        WHERE plugin_id = \(quoted(pluginID))
          AND vendor_thread_id = \(quoted(vendorThreadID))
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Self.sqliteError(handle: handle, fallback: "Failed to prepare messaging thread vendor lookup.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try decodeMessagingThread(statement: statement)
    }

    private func loadMessagingMessage(
        threadID: String,
        vendorMessageID: String,
        on handle: OpaquePointer
    ) throws -> MessagingMessageDTO? {
        let sql = """
        SELECT id, thread_id, vendor_message_id, direction, sender, body, created_at,
               parent_vendor_message_id, reply_count
        FROM messaging_messages
        WHERE thread_id = \(quoted(threadID))
          AND vendor_message_id = \(quoted(vendorMessageID))
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Self.sqliteError(handle: handle, fallback: "Failed to prepare messaging vendor lookup.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try decodeMessagingMessage(statement: statement)
    }

    private func loadMessagingMessage(id: String, on handle: OpaquePointer) throws -> MessagingMessageDTO? {
        let sql = """
        SELECT id, thread_id, vendor_message_id, direction, sender, body, created_at,
               parent_vendor_message_id, reply_count
        FROM messaging_messages
        WHERE id = \(quoted(id))
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Self.sqliteError(handle: handle, fallback: "Failed to prepare messaging id lookup.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try decodeMessagingMessage(statement: statement)
    }

    private func decodeMessagingConnector(statement: OpaquePointer) throws -> MessagingConnectorDTO {
        let listeningSinceRaw = columnOptionalString(statement, index: 5)
        let listeningSince = listeningSinceRaw.flatMap {
            Self.iso8601Formatter().date(from: $0)
        }
        return MessagingConnectorDTO(
            pluginID: try columnString(statement, index: 0),
            displayName: try columnString(statement, index: 1),
            listening: sqlite3_column_int(statement, 2) != 0,
            unreadCount: Int(sqlite3_column_int(statement, 6)),
            listeningSince: listeningSince,
            createdAt: Self.iso8601Formatter().date(from: try columnString(statement, index: 3)) ?? .now,
            updatedAt: Self.iso8601Formatter().date(from: try columnString(statement, index: 4)) ?? .now
        )
    }

    private func decodeMessagingThread(statement: OpaquePointer) throws -> MessagingThreadDTO {
        MessagingThreadDTO(
            id: try columnString(statement, index: 0),
            pluginID: try columnString(statement, index: 1),
            vendorThreadID: try columnString(statement, index: 2),
            title: try columnString(statement, index: 3),
            lastActivityAt: Self.iso8601Formatter().date(from: try columnString(statement, index: 4)) ?? .now,
            muted: sqlite3_column_int(statement, 5) != 0,
            unreadCount: Int(sqlite3_column_int(statement, 6)),
            defaultAgentProfileHandle: columnOptionalString(statement, index: 8),
            createdAt: Self.iso8601Formatter().date(from: try columnString(statement, index: 7)) ?? .now
        )
    }

    private func decodeMessagingMessage(statement: OpaquePointer) throws -> MessagingMessageDTO {
        let directionRaw = try columnString(statement, index: 3)
        return MessagingMessageDTO(
            id: try columnString(statement, index: 0),
            threadID: try columnString(statement, index: 1),
            vendorMessageID: columnOptionalString(statement, index: 2),
            direction: MessagingMessageDirection(rawValue: directionRaw) ?? .inbound,
            sender: try columnString(statement, index: 4),
            body: try columnString(statement, index: 5),
            createdAt: Self.iso8601Formatter().date(from: try columnString(statement, index: 6)) ?? .now,
            parentVendorMessageID: columnOptionalString(statement, index: 7),
            replyCount: Int(sqlite3_column_int(statement, 8))
        )
    }
}
