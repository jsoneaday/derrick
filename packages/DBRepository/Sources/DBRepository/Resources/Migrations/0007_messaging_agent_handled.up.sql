CREATE TABLE IF NOT EXISTS messaging_agent_handled (
    plugin_id TEXT NOT NULL,
    vendor_message_id TEXT NOT NULL,
    handled_at TEXT NOT NULL,
    PRIMARY KEY (plugin_id, vendor_message_id)
);
