CREATE TABLE IF NOT EXISTS jobs (
    id TEXT PRIMARY KEY NOT NULL,
    status TEXT NOT NULL,
    principal_json TEXT NOT NULL,
    source TEXT NOT NULL,
    correlation_id TEXT,
    run_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    error_message TEXT
);

CREATE INDEX IF NOT EXISTS idx_jobs_status_run_at
    ON jobs(status, run_at);

CREATE INDEX IF NOT EXISTS idx_jobs_created
    ON jobs(created_at DESC);

CREATE TABLE IF NOT EXISTS job_steps (
    id TEXT PRIMARY KEY NOT NULL,
    job_id TEXT NOT NULL,
    step_index INTEGER NOT NULL,
    kind TEXT NOT NULL,
    status TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    result_json TEXT,
    error_message TEXT,
    started_at TEXT,
    finished_at TEXT,
    FOREIGN KEY(job_id) REFERENCES jobs(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_job_steps_job_index
    ON job_steps(job_id, step_index);
