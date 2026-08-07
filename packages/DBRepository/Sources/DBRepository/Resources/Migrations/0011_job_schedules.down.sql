DROP INDEX IF EXISTS idx_job_schedules_enabled_next;
DROP TABLE IF EXISTS job_schedules;
DROP INDEX IF EXISTS idx_jobs_schedule_id;
-- SQLite cannot DROP COLUMN portably on older versions; leave schedule_id if present.
