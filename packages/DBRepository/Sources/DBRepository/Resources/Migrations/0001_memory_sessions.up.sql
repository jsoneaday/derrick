CREATE TABLE IF NOT EXISTS memory_sessions (
    application_name TEXT NOT NULL,
    session_id TEXT NOT NULL,
    agent_id TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (application_name, session_id, agent_id)
);
