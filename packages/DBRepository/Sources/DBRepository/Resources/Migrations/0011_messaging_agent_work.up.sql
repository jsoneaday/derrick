CREATE TABLE IF NOT EXISTS messaging_agent_work (
    plugin_id TEXT NOT NULL,
    thread_id TEXT NOT NULL,
    parent_vendor_message_id TEXT NOT NULL,
    profile_handle TEXT NOT NULL,
    display_name TEXT NOT NULL,
    started_at TEXT NOT NULL,
    PRIMARY KEY (plugin_id, thread_id, parent_vendor_message_id)
);
