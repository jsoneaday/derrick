ALTER TABLE job_results ADD COLUMN notify_posted INTEGER NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_job_results_notify ON job_results(notify_posted);
