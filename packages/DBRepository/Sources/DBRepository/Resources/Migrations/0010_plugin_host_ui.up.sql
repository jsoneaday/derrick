CREATE TABLE IF NOT EXISTS plugin_host_ui (
    plugin_id TEXT PRIMARY KEY NOT NULL,
    present_json TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
