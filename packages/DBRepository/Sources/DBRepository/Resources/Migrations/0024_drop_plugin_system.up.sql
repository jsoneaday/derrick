-- Remove persisted plugin installs, invoke history, and plugin-owned jobs.
DELETE FROM memory_records
WHERE lower(prompt || ' ' || completion || ' '
    || coalesce(compressed_summary_text, '') || ' '
    || coalesce(detailed_summary_text, '')) LIKE '%plugin.invoke%'
   OR lower(prompt || ' ' || completion || ' '
    || coalesce(compressed_summary_text, '') || ' '
    || coalesce(detailed_summary_text, '')) LIKE '%plugin.list%'
   OR lower(prompt || ' ' || completion || ' '
    || coalesce(compressed_summary_text, '') || ' '
    || coalesce(detailed_summary_text, '')) LIKE '%create-plugin%'
   OR lower(prompt || ' ' || completion || ' '
    || coalesce(compressed_summary_text, '') || ' '
    || coalesce(detailed_summary_text, '')) LIKE '%software factory%';

DELETE FROM jobs
WHERE id IN (
    SELECT job_id
    FROM job_steps
    WHERE payload_json LIKE '%plugin.invoke%'
);

DELETE FROM job_schedules
WHERE steps_json LIKE '%plugin.invoke%';

DROP INDEX IF EXISTS idx_pending_plugin_waits_invoke;
DROP TABLE IF EXISTS pending_plugin_waits;
DROP INDEX IF EXISTS idx_plugin_invokes_plugin;
DROP TABLE IF EXISTS plugin_invokes;
DROP INDEX IF EXISTS idx_plugin_grants_plugin;
DROP TABLE IF EXISTS plugin_grants;
DROP INDEX IF EXISTS idx_plugin_versions_plugin;
DROP TABLE IF EXISTS plugin_versions;
DROP TABLE IF EXISTS plugins;
