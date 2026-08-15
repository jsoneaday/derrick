DROP INDEX IF EXISTS idx_policy_approvals_rule;
DROP INDEX IF EXISTS idx_policy_approvals_session;

CREATE TABLE IF NOT EXISTS policy_approvals_rebuild (
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

INSERT INTO policy_approvals_rebuild (
    id, application_name, session_id, rule_id, request_type,
    request_payload_json, edited_payload_json, decision, actor, created_at, acted_at
)
SELECT
    id, application_name, session_id, rule_id, request_type,
    request_payload_json, edited_payload_json, decision, actor, created_at, acted_at
FROM policy_approvals;

DROP TABLE policy_approvals;
ALTER TABLE policy_approvals_rebuild RENAME TO policy_approvals;

CREATE INDEX IF NOT EXISTS idx_policy_approvals_session
    ON policy_approvals(application_name, session_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_policy_approvals_rule
    ON policy_approvals(rule_id, created_at DESC);
