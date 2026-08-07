-- Link job runs to schedule templates (nullable for ad-hoc jobs).
ALTER TABLE jobs ADD COLUMN schedule_id TEXT;

CREATE INDEX IF NOT EXISTS idx_jobs_schedule_id
    ON jobs(schedule_id);

-- Recurring / one-shot schedule definitions (spawn job runs when due).
CREATE TABLE IF NOT EXISTS job_schedules (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    enabled INTEGER NOT NULL,
    principal_json TEXT NOT NULL,
    source TEXT NOT NULL,
    recurrence_kind TEXT NOT NULL,
    interval_seconds INTEGER,
    steps_json TEXT NOT NULL,
    next_fire_at TEXT,
    last_fired_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_job_schedules_enabled_next
    ON job_schedules(enabled, next_fire_at);
