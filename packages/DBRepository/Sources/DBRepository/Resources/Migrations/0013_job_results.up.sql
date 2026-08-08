-- Job wake completions for modal / notification delivery (isolated from chat session).
CREATE TABLE IF NOT EXISTS job_results (
    id TEXT PRIMARY KEY NOT NULL,
    job_id TEXT NOT NULL,
    job_session_id TEXT NOT NULL,
    parent_session_id TEXT,
    response_text TEXT NOT NULL,
    created_at TEXT NOT NULL,
    read_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_job_results_created
    ON job_results(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_job_results_job_id
    ON job_results(job_id);
