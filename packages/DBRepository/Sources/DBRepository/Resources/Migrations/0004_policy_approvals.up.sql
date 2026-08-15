CREATE TABLE IF NOT EXISTS policy_approvals (
    id TEXT PRIMARY KEY NOT NULL,
    application_name TEXT NOT NULL,
    session_id TEXT NOT NULL,
    rule_id TEXT NOT NULL,
    request_type TEXT NOT NULL,
    request_payload_json TEXT NOT NULL,
    edited_payload_json TEXT,
    decision TEXT NOT NULL,
    actor TEXT,
    created_at TEXT NOT NULL,
    acted_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_policy_approvals_session
    ON policy_approvals(application_name, session_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_policy_approvals_rule
    ON policy_approvals(rule_id, created_at DESC);
