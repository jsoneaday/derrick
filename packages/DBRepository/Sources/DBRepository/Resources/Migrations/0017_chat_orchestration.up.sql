CREATE TABLE IF NOT EXISTS chat_sessions (
    application_name TEXT NOT NULL,
    session_id TEXT NOT NULL,
    title TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    PRIMARY KEY (application_name, session_id)
);

CREATE INDEX IF NOT EXISTS idx_chat_sessions_updated
    ON chat_sessions(application_name, updated_at DESC);

CREATE TABLE IF NOT EXISTS agents (
    application_name TEXT NOT NULL,
    session_id TEXT NOT NULL,
    agent_id TEXT NOT NULL,
    role TEXT NOT NULL,
    parent_agent_id TEXT,
    status TEXT NOT NULL,
    goal TEXT,
    system_overlay TEXT,
    model_preference TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    PRIMARY KEY (application_name, session_id, agent_id),
    FOREIGN KEY(application_name, session_id)
        REFERENCES chat_sessions(application_name, session_id)
        ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_agents_session
    ON agents(application_name, session_id);

CREATE TABLE IF NOT EXISTS agent_turns (
    id TEXT PRIMARY KEY NOT NULL,
    application_name TEXT NOT NULL,
    session_id TEXT NOT NULL,
    agent_id TEXT NOT NULL,
    correlation_id TEXT,
    envelope_kind TEXT NOT NULL,
    status TEXT NOT NULL,
    prompt_preview TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY(application_name, session_id, agent_id)
        REFERENCES agents(application_name, session_id, agent_id)
        ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_agent_turns_session_agent
    ON agent_turns(application_name, session_id, agent_id, created_at DESC);
