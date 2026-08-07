-- Structured failure + non-terminal status notes for jobs.
ALTER TABLE jobs ADD COLUMN error_code TEXT;
ALTER TABLE jobs ADD COLUMN status_detail TEXT;
