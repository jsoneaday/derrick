CREATE TABLE IF NOT EXISTS plugin_factory_releases (
    plugin_id TEXT NOT NULL,
    version TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    manifest_json TEXT NOT NULL,
    runtime_json TEXT NOT NULL,
    swift_source TEXT NOT NULL,
    artifact_base64 TEXT NOT NULL,
    skill_files_json TEXT NOT NULL DEFAULT '{}',
    review_summary TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (plugin_id, version),
    UNIQUE (content_hash)
);
