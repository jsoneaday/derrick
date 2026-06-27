CREATE TABLE IF NOT EXISTS memory_sessions (
    id TEXT PRIMARY KEY NOT NULL,
    application_name TEXT NOT NULL,
    session_id TEXT NOT NULL,
    agent_id TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(application_name, session_id, agent_id)
);

CREATE INDEX IF NOT EXISTS idx_memory_sessions_lookup
    ON memory_sessions(application_name, session_id, agent_id);
