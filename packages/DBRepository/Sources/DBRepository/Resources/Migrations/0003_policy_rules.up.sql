CREATE TABLE IF NOT EXISTS policy_rules (
    id TEXT PRIMARY KEY NOT NULL,
    application_name TEXT NOT NULL,
    name TEXT NOT NULL,
    scope TEXT NOT NULL,
    matcher_json TEXT NOT NULL,
    outcome_json TEXT NOT NULL,
    priority INTEGER NOT NULL DEFAULT 100,
    enabled INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_policy_rules_lookup
    ON policy_rules(application_name, scope, enabled, priority DESC);

CREATE INDEX IF NOT EXISTS idx_policy_rules_app
    ON policy_rules(application_name);
