CREATE TABLE IF NOT EXISTS factory_sessions (
    session_id TEXT PRIMARY KEY,
    spec_json TEXT,
    stage TEXT NOT NULL,
    plugin_id TEXT,
    instruction_plugin_id TEXT,
    reviewer_calls INTEGER NOT NULL DEFAULT 0,
    harness_runs INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
