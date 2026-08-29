CREATE TABLE IF NOT EXISTS messaging_connectors (
    plugin_id TEXT PRIMARY KEY NOT NULL,
    display_name TEXT NOT NULL,
    listening INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS messaging_threads (
    id TEXT PRIMARY KEY NOT NULL,
    plugin_id TEXT NOT NULL,
    vendor_thread_id TEXT NOT NULL,
    title TEXT NOT NULL,
    last_activity_at TEXT NOT NULL,
    muted INTEGER NOT NULL DEFAULT 0,
    unread_count INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    FOREIGN KEY(plugin_id) REFERENCES messaging_connectors(plugin_id) ON DELETE CASCADE,
    UNIQUE (plugin_id, vendor_thread_id)
);

CREATE INDEX IF NOT EXISTS idx_messaging_threads_plugin_activity
    ON messaging_threads(plugin_id, last_activity_at DESC);

CREATE TABLE IF NOT EXISTS messaging_messages (
    id TEXT PRIMARY KEY NOT NULL,
    thread_id TEXT NOT NULL,
    vendor_message_id TEXT,
    direction TEXT NOT NULL,
    sender TEXT NOT NULL,
    body TEXT NOT NULL,
    created_at TEXT NOT NULL,
    FOREIGN KEY(thread_id) REFERENCES messaging_threads(id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_messaging_messages_vendor
    ON messaging_messages(thread_id, vendor_message_id)
    WHERE vendor_message_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_messaging_messages_thread_created
    ON messaging_messages(thread_id, created_at DESC, id DESC);
