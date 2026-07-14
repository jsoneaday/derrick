CREATE TABLE IF NOT EXISTS memory_records (
    id TEXT PRIMARY KEY NOT NULL,
    application_name TEXT NOT NULL,
    session_id TEXT NOT NULL,
    agent_id TEXT NOT NULL,
    parent_agent_id TEXT,
    scope TEXT NOT NULL,
    created_at TEXT NOT NULL,
    prompt TEXT NOT NULL,
    completion TEXT NOT NULL,
    tool_calls_json TEXT NOT NULL DEFAULT '[]',
    prompt_token_count INTEGER NOT NULL,
    completion_token_count INTEGER NOT NULL,
    compressed_summary_text TEXT,
    compressed_summary_keywords_json TEXT,
    compressed_summary_semantic_similarity REAL,
    compressed_summary_compression_ratio REAL,
    compressed_summary_source_token_count INTEGER,
    compressed_summary_token_count INTEGER,
    detailed_summary_text TEXT,
    detailed_summary_keywords_json TEXT,
    detailed_summary_semantic_similarity REAL,
    detailed_summary_compression_ratio REAL,
    detailed_summary_source_token_count INTEGER,
    detailed_summary_token_count INTEGER,
    FOREIGN KEY(application_name, session_id, agent_id)
        REFERENCES memory_sessions(application_name, session_id, agent_id)
        ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_memory_records_session_created_at
    ON memory_records(application_name, session_id, agent_id, created_at DESC);
