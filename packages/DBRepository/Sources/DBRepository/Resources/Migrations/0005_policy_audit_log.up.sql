CREATE TABLE IF NOT EXISTS policy_audit_log (
    id TEXT PRIMARY KEY NOT NULL,
    application_name TEXT NOT NULL,
    session_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    scope TEXT NOT NULL,
    request_json TEXT NOT NULL,
    decision TEXT NOT NULL,
    reason TEXT,
    actor TEXT,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_policy_audit_session
    ON policy_audit_log(application_name, session_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_policy_audit_event
    ON policy_audit_log(event_type, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_policy_audit_decision
    ON policy_audit_log(decision, created_at DESC);
