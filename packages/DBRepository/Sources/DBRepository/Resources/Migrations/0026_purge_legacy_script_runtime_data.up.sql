-- Remove persisted source and metadata created by the retired JavaScript
-- runtime. The predicates deliberately keep current standalone Swift runs.

DELETE FROM pending_hitl_approvals
WHERE lower(coalesce(arguments_json, '') || ' ' || coalesce(edited_arguments_json, ''))
      LIKE '%script.%'
   OR lower(coalesce(arguments_json, '') || ' ' || coalesce(edited_arguments_json, ''))
      LIKE '%function handle%'
   OR lower(coalesce(arguments_json, '') || ' ' || coalesce(edited_arguments_json, ''))
      LIKE '%import {%netfetch%';

DELETE FROM policy_approvals
WHERE lower(coalesce(request_payload_json, '') || ' ' || coalesce(edited_payload_json, ''))
      LIKE '%script.%'
   OR lower(coalesce(request_payload_json, '') || ' ' || coalesce(edited_payload_json, ''))
      LIKE '%function handle%'
   OR lower(coalesce(request_payload_json, '') || ' ' || coalesce(edited_payload_json, ''))
      LIKE '%import {%netfetch%';

DELETE FROM job_schedules
WHERE lower(coalesce(steps_json, '')) LIKE '%script.%'
   OR lower(coalesce(steps_json, '')) LIKE '%function handle%'
   OR lower(coalesce(steps_json, '')) LIKE '%import {%netfetch%';

DELETE FROM jobs
WHERE lower(coalesce(principal_json, '') || ' ' || coalesce(source, '') || ' '
    || coalesce(error_message, '')) LIKE '%script.%'
   OR lower(coalesce(principal_json, '') || ' ' || coalesce(source, '') || ' '
    || coalesce(error_message, '')) LIKE '%function handle%'
   OR lower(coalesce(principal_json, '') || ' ' || coalesce(source, '') || ' '
    || coalesce(error_message, '')) LIKE '%import {%netfetch%'
   OR id IN (
        SELECT job_id
        FROM job_steps
        WHERE lower(coalesce(payload_json, '') || ' ' || coalesce(result_json, '') || ' '
            || coalesce(error_message, '')) LIKE '%script.%'
           OR lower(coalesce(payload_json, '') || ' ' || coalesce(result_json, '') || ' '
            || coalesce(error_message, '')) LIKE '%function handle%'
           OR lower(coalesce(payload_json, '') || ' ' || coalesce(result_json, '') || ' '
            || coalesce(error_message, '')) LIKE '%import {%netfetch%'
    );

DELETE FROM job_steps
WHERE lower(coalesce(payload_json, '') || ' ' || coalesce(result_json, '') || ' '
    || coalesce(error_message, '')) LIKE '%script.%'
   OR lower(coalesce(payload_json, '') || ' ' || coalesce(result_json, '') || ' '
    || coalesce(error_message, '')) LIKE '%function handle%'
   OR lower(coalesce(payload_json, '') || ' ' || coalesce(result_json, '') || ' '
    || coalesce(error_message, '')) LIKE '%import {%netfetch%';

DELETE FROM memory_records
WHERE lower(prompt || ' ' || completion || ' '
    || coalesce(compressed_summary_text, '') || ' '
    || coalesce(detailed_summary_text, '')) LIKE '%script.%'
   OR lower(prompt || ' ' || completion || ' '
    || coalesce(compressed_summary_text, '') || ' '
    || coalesce(detailed_summary_text, '')) LIKE '%function handle%'
   OR lower(prompt || ' ' || completion || ' '
    || coalesce(compressed_summary_text, '') || ' '
    || coalesce(detailed_summary_text, '')) LIKE '%import {%netfetch%';

DELETE FROM agents
WHERE lower(coalesce(goal, '') || ' ' || coalesce(system_overlay, '') || ' '
    || coalesce(metadata_json, '')) LIKE '%script.%'
   OR lower(coalesce(goal, '') || ' ' || coalesce(system_overlay, '') || ' '
    || coalesce(metadata_json, '')) LIKE '%function handle%'
   OR lower(coalesce(goal, '') || ' ' || coalesce(system_overlay, '') || ' '
    || coalesce(metadata_json, '')) LIKE '%import {%netfetch%';

DELETE FROM chat_sessions
WHERE lower(coalesce(title, '') || ' ' || coalesce(metadata_json, ''))
      LIKE '%script.%'
   OR lower(coalesce(title, '') || ' ' || coalesce(metadata_json, ''))
      LIKE '%function handle%'
   OR lower(coalesce(title, '') || ' ' || coalesce(metadata_json, ''))
      LIKE '%import {%netfetch%';

DELETE FROM service_logs
WHERE lower(coalesce(message, '') || ' ' || coalesce(detail_json, ''))
      LIKE '%script.%'
   OR lower(coalesce(message, '') || ' ' || coalesce(detail_json, ''))
      LIKE '%function handle%'
   OR lower(coalesce(message, '') || ' ' || coalesce(detail_json, ''))
      LIKE '%import {%netfetch%';
