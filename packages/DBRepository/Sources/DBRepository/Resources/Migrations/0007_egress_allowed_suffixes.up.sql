CREATE TABLE IF NOT EXISTS egress_allowed_domain_suffixes (
    id TEXT PRIMARY KEY NOT NULL,
    suffix TEXT NOT NULL UNIQUE,
    source TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_egress_allowed_suffixes_enabled
    ON egress_allowed_domain_suffixes(enabled, suffix);
