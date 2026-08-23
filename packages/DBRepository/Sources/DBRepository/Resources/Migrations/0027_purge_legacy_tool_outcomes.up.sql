-- Remove persisted pre-unified script and plugin execution-result payloads.
-- Current ToolExecutionOutcome records use stage/diagnostics/metrics instead.

UPDATE memory_records
SET tool_calls_json = '[]'
WHERE lower(coalesce(tool_calls_json, '')) LIKE '%failurestage%'
   OR lower(coalesce(tool_calls_json, '')) LIKE '%reviewerassessment%'
   OR lower(coalesce(tool_calls_json, '')) LIKE '%phasetiming%';

DELETE FROM memory_records
WHERE lower(coalesce(completion, '') || ' '
    || coalesce(compressed_summary_text, '') || ' '
    || coalesce(detailed_summary_text, '')) LIKE '%failurestage%'
   OR lower(coalesce(completion, '') || ' '
    || coalesce(compressed_summary_text, '') || ' '
    || coalesce(detailed_summary_text, '')) LIKE '%reviewerassessment%'
   OR lower(coalesce(completion, '') || ' '
    || coalesce(compressed_summary_text, '') || ' '
    || coalesce(detailed_summary_text, '')) LIKE '%phasetiming%';

UPDATE job_steps
SET result_json = NULL
WHERE lower(coalesce(result_json, '')) LIKE '%failurestage%'
   OR lower(coalesce(result_json, '')) LIKE '%reviewerassessment%'
   OR lower(coalesce(result_json, '')) LIKE '%phasetiming%';

DELETE FROM job_results
WHERE lower(coalesce(response_text, '')) LIKE '%failurestage%'
   OR lower(coalesce(response_text, '')) LIKE '%reviewerassessment%'
   OR lower(coalesce(response_text, '')) LIKE '%phasetiming%';

DELETE FROM service_logs
WHERE lower(coalesce(message, '') || ' ' || coalesce(detail_json, '')) LIKE '%failurestage%'
   OR lower(coalesce(message, '') || ' ' || coalesce(detail_json, '')) LIKE '%reviewerassessment%'
   OR lower(coalesce(message, '') || ' ' || coalesce(detail_json, '')) LIKE '%phasetiming%';
