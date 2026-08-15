CREATE TABLE IF NOT EXISTS plugins (
    id TEXT PRIMARY KEY NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    current_version_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS plugin_versions (
    id TEXT PRIMARY KEY NOT NULL,
    plugin_id TEXT NOT NULL,
    version TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    status TEXT NOT NULL,
    volume_name TEXT,
    manifest_json TEXT NOT NULL,
    runtime_json TEXT,
    dependencies_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL,
    FOREIGN KEY(plugin_id) REFERENCES plugins(id) ON DELETE CASCADE,
    UNIQUE (plugin_id, version),
    UNIQUE (plugin_id, content_hash)
);

CREATE INDEX IF NOT EXISTS idx_plugin_versions_plugin
    ON plugin_versions(plugin_id);

CREATE TABLE IF NOT EXISTS plugin_grants (
    id TEXT PRIMARY KEY NOT NULL,
    plugin_id TEXT NOT NULL,
    version_id TEXT NOT NULL,
    auth_refs_json TEXT NOT NULL DEFAULT '[]',
    attach_hosts_json TEXT NOT NULL DEFAULT '[]',
    notify_session_id TEXT,
    dependencies_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL,
    FOREIGN KEY(plugin_id) REFERENCES plugins(id) ON DELETE CASCADE,
    FOREIGN KEY(version_id) REFERENCES plugin_versions(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_plugin_grants_plugin
    ON plugin_grants(plugin_id);

CREATE TABLE IF NOT EXISTS plugin_invokes (
    id TEXT PRIMARY KEY NOT NULL,
    plugin_id TEXT,
    version_id TEXT,
    invoke_id TEXT NOT NULL UNIQUE,
    kind TEXT NOT NULL,
    status TEXT NOT NULL,
    hop INTEGER NOT NULL DEFAULT 0,
    principal_json TEXT NOT NULL,
    result_json TEXT,
    error_message TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY(plugin_id) REFERENCES plugins(id) ON DELETE SET NULL,
    FOREIGN KEY(version_id) REFERENCES plugin_versions(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_plugin_invokes_plugin
    ON plugin_invokes(plugin_id);

CREATE TABLE IF NOT EXISTS pending_plugin_waits (
    id TEXT PRIMARY KEY NOT NULL,
    invoke_id TEXT NOT NULL,
    plugin_id TEXT,
    kind TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    FOREIGN KEY(invoke_id) REFERENCES plugin_invokes(invoke_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_pending_plugin_waits_invoke
    ON pending_plugin_waits(invoke_id);

CREATE TABLE IF NOT EXISTS factory_sessions (
    session_id TEXT PRIMARY KEY NOT NULL,
    spec_json TEXT,
    stage TEXT NOT NULL,
    plugin_id TEXT,
    reviewer_calls INTEGER NOT NULL DEFAULT 0,
    harness_runs INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS egress_blacklist (
    id TEXT PRIMARY KEY NOT NULL,
    pattern TEXT NOT NULL,
    kind TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE (kind, pattern)
);

CREATE TABLE IF NOT EXISTS egress_blacklist_exceptions (
    id TEXT PRIMARY KEY NOT NULL,
    pattern TEXT NOT NULL,
    kind TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE (kind, pattern)
);
