CREATE TABLE IF NOT EXISTS content_sensitivity_grants (
    id TEXT PRIMARY KEY NOT NULL,
    category TEXT NOT NULL,
    scope TEXT NOT NULL,
    session_id TEXT,
    actor TEXT,
    enabled INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_content_sensitivity_grants_permanent_category
    ON content_sensitivity_grants(category)
    WHERE scope = 'permanent' AND enabled = 1;

CREATE INDEX IF NOT EXISTS idx_content_sensitivity_grants_session
    ON content_sensitivity_grants(session_id, category)
    WHERE scope = 'session' AND enabled = 1;
