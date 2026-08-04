CREATE TABLE IF NOT EXISTS service_logs (
    id TEXT PRIMARY KEY NOT NULL,
    service TEXT NOT NULL,
    level TEXT NOT NULL,
    code TEXT,
    message TEXT NOT NULL,
    detail_json TEXT,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_service_logs_service_created
    ON service_logs(service, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_service_logs_created
    ON service_logs(created_at DESC);
