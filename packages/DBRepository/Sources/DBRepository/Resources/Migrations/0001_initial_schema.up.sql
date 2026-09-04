-- Canonical Derrick schema (dev). No incremental upgrade path from prior versions.

CREATE TABLE IF NOT EXISTS memory_sessions (
    application_name TEXT NOT NULL,
    session_id TEXT NOT NULL,
    agent_id TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (application_name, session_id, agent_id)
);

CREATE TABLE IF NOT EXISTS memory_records (
    id TEXT PRIMARY KEY NOT NULL,
    application_name TEXT NOT NULL,
    session_id TEXT NOT NULL,
    agent_id TEXT NOT NULL,
    parent_agent_id TEXT,
    scope TEXT NOT NULL,
    created_at TEXT NOT NULL,
    prompt TEXT NOT NULL,
    completion TEXT NOT NULL,
    tool_calls_json TEXT NOT NULL DEFAULT '[]',
    prompt_token_count INTEGER NOT NULL,
    completion_token_count INTEGER NOT NULL,
    compressed_summary_text TEXT,
    compressed_summary_keywords_json TEXT,
    compressed_summary_semantic_similarity REAL,
    compressed_summary_compression_ratio REAL,
    compressed_summary_source_token_count INTEGER,
    compressed_summary_token_count INTEGER,
    detailed_summary_text TEXT,
    detailed_summary_keywords_json TEXT,
    detailed_summary_semantic_similarity REAL,
    detailed_summary_compression_ratio REAL,
    detailed_summary_source_token_count INTEGER,
    detailed_summary_token_count INTEGER,
    FOREIGN KEY(application_name, session_id, agent_id)
        REFERENCES memory_sessions(application_name, session_id, agent_id)
        ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_memory_records_session_created_at
    ON memory_records(application_name, session_id, agent_id, created_at DESC);

CREATE TABLE IF NOT EXISTS policy_rules (
    id TEXT PRIMARY KEY NOT NULL,
    application_name TEXT NOT NULL,
    name TEXT NOT NULL,
    scope TEXT NOT NULL,
    matcher_json TEXT NOT NULL,
    outcome_json TEXT NOT NULL,
    priority INTEGER NOT NULL DEFAULT 100,
    enabled INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_policy_rules_lookup
    ON policy_rules(application_name, scope, enabled, priority DESC);

CREATE INDEX IF NOT EXISTS idx_policy_rules_app
    ON policy_rules(application_name);

CREATE TABLE IF NOT EXISTS policy_approvals (
    id TEXT PRIMARY KEY NOT NULL,
    application_name TEXT NOT NULL,
    session_id TEXT NOT NULL,
    rule_id TEXT NOT NULL,
    request_type TEXT NOT NULL,
    request_payload_json TEXT NOT NULL,
    edited_payload_json TEXT,
    decision TEXT NOT NULL,
    actor TEXT,
    created_at TEXT NOT NULL,
    acted_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_policy_approvals_session
    ON policy_approvals(application_name, session_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_policy_approvals_rule
    ON policy_approvals(rule_id, created_at DESC);

CREATE TABLE IF NOT EXISTS policy_audit_log (
    id TEXT PRIMARY KEY NOT NULL,
    application_name TEXT NOT NULL,
    session_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    scope TEXT NOT NULL,
    request_json TEXT NOT NULL,
    decision TEXT NOT NULL,
    reason TEXT,
    actor TEXT,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_policy_audit_session
    ON policy_audit_log(application_name, session_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_policy_audit_event
    ON policy_audit_log(event_type, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_policy_audit_decision
    ON policy_audit_log(decision, created_at DESC);

CREATE TABLE IF NOT EXISTS configurations (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS egress_allowed_domain_suffixes (
    id TEXT PRIMARY KEY NOT NULL,
    suffix TEXT NOT NULL UNIQUE,
    source TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_egress_allowed_suffixes_enabled
    ON egress_allowed_domain_suffixes(enabled, suffix);

CREATE TABLE IF NOT EXISTS content_sensitivity_grants (
    id TEXT PRIMARY KEY NOT NULL,
    category TEXT NOT NULL,
    scope TEXT NOT NULL,
    session_id TEXT,
    actor TEXT,
    enabled INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_content_sensitivity_grants_permanent_category
    ON content_sensitivity_grants(category)
    WHERE scope = 'permanent' AND enabled = 1;

CREATE INDEX IF NOT EXISTS idx_content_sensitivity_grants_session
    ON content_sensitivity_grants(session_id, category)
    WHERE scope = 'session' AND enabled = 1;

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

CREATE TABLE IF NOT EXISTS jobs (
    id TEXT PRIMARY KEY NOT NULL,
    status TEXT NOT NULL,
    principal_json TEXT NOT NULL,
    source TEXT NOT NULL,
    correlation_id TEXT,
    run_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    error_message TEXT,
    schedule_id TEXT,
    error_code TEXT,
    status_detail TEXT
);

CREATE INDEX IF NOT EXISTS idx_jobs_status_run_at
    ON jobs(status, run_at);

CREATE INDEX IF NOT EXISTS idx_jobs_created
    ON jobs(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_jobs_schedule_id
    ON jobs(schedule_id);

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

CREATE TABLE IF NOT EXISTS job_results (
    id TEXT PRIMARY KEY NOT NULL,
    job_id TEXT NOT NULL,
    job_session_id TEXT NOT NULL,
    parent_session_id TEXT,
    response_text TEXT NOT NULL,
    created_at TEXT NOT NULL,
    read_at TEXT,
    notify_posted INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_job_results_created
    ON job_results(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_job_results_job_id
    ON job_results(job_id);

CREATE INDEX IF NOT EXISTS idx_job_results_notify
    ON job_results(notify_posted);

CREATE TABLE IF NOT EXISTS pending_hitl_approvals (
    id TEXT PRIMARY KEY,
    turn_id TEXT NOT NULL,
    session_id TEXT NOT NULL,
    tool_name TEXT NOT NULL,
    arguments_json TEXT NOT NULL,
    required_fields_json TEXT NOT NULL DEFAULT '[]',
    status TEXT NOT NULL DEFAULT 'pending',
    edited_arguments_json TEXT,
    actor TEXT,
    notify_posted INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    decided_at TEXT,
    is_job_context INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_pending_hitl_status ON pending_hitl_approvals(status);
CREATE INDEX IF NOT EXISTS idx_pending_hitl_notify ON pending_hitl_approvals(notify_posted, status);

CREATE TABLE IF NOT EXISTS chat_sessions (
    application_name TEXT NOT NULL,
    session_id TEXT NOT NULL,
    title TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    PRIMARY KEY (application_name, session_id)
);

CREATE INDEX IF NOT EXISTS idx_chat_sessions_updated
    ON chat_sessions(application_name, updated_at DESC);

CREATE TABLE IF NOT EXISTS agents (
    application_name TEXT NOT NULL,
    session_id TEXT NOT NULL,
    agent_id TEXT NOT NULL,
    role TEXT NOT NULL,
    parent_agent_id TEXT,
    status TEXT NOT NULL,
    goal TEXT,
    system_overlay TEXT,
    model_preference TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    PRIMARY KEY (application_name, session_id, agent_id),
    FOREIGN KEY(application_name, session_id)
        REFERENCES chat_sessions(application_name, session_id)
        ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_agents_session
    ON agents(application_name, session_id);

CREATE TABLE IF NOT EXISTS agent_turns (
    id TEXT PRIMARY KEY NOT NULL,
    application_name TEXT NOT NULL,
    session_id TEXT NOT NULL,
    agent_id TEXT NOT NULL,
    correlation_id TEXT,
    envelope_kind TEXT NOT NULL,
    status TEXT NOT NULL,
    prompt_preview TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY(application_name, session_id, agent_id)
        REFERENCES agents(application_name, session_id, agent_id)
        ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_agent_turns_session_agent
    ON agent_turns(application_name, session_id, agent_id, created_at DESC);

CREATE TABLE IF NOT EXISTS egress_blacklist (
    id TEXT PRIMARY KEY NOT NULL,
    pattern TEXT NOT NULL,
    kind TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE (kind, pattern)
);

CREATE TABLE IF NOT EXISTS egress_blacklist_exceptions (
    id TEXT PRIMARY KEY NOT NULL,
    pattern TEXT NOT NULL,
    kind TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE (kind, pattern)
);

CREATE TABLE IF NOT EXISTS plugin_factory_releases (
    plugin_id TEXT NOT NULL,
    version TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    manifest_json TEXT NOT NULL,
    runtime_json TEXT NOT NULL,
    swift_source TEXT NOT NULL,
    artifact_base64 TEXT NOT NULL,
    skill_files_json TEXT NOT NULL DEFAULT '{}',
    review_summary TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (plugin_id, version),
    UNIQUE (content_hash)
);

CREATE TABLE IF NOT EXISTS messaging_connectors (
    plugin_id TEXT PRIMARY KEY NOT NULL,
    display_name TEXT NOT NULL,
    listening INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS messaging_threads (
    id TEXT PRIMARY KEY NOT NULL,
    plugin_id TEXT NOT NULL,
    vendor_thread_id TEXT NOT NULL,
    title TEXT NOT NULL,
    last_activity_at TEXT NOT NULL,
    muted INTEGER NOT NULL DEFAULT 0,
    unread_count INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    FOREIGN KEY(plugin_id) REFERENCES messaging_connectors(plugin_id) ON DELETE CASCADE,
    UNIQUE (plugin_id, vendor_thread_id)
);

CREATE INDEX IF NOT EXISTS idx_messaging_threads_plugin_activity
    ON messaging_threads(plugin_id, last_activity_at DESC);

CREATE TABLE IF NOT EXISTS messaging_messages (
    id TEXT PRIMARY KEY NOT NULL,
    thread_id TEXT NOT NULL,
    vendor_message_id TEXT,
    direction TEXT NOT NULL,
    sender TEXT NOT NULL,
    body TEXT NOT NULL,
    created_at TEXT NOT NULL,
    FOREIGN KEY(thread_id) REFERENCES messaging_threads(id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_messaging_messages_vendor
    ON messaging_messages(thread_id, vendor_message_id)
    WHERE vendor_message_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_messaging_messages_thread_created
    ON messaging_messages(thread_id, created_at DESC, id DESC);

CREATE TABLE IF NOT EXISTS tool_runs (
    id TEXT PRIMARY KEY NOT NULL,
    tool_name TEXT NOT NULL,
    arguments_json TEXT NOT NULL,
    principal_json TEXT NOT NULL,
    context_json TEXT NOT NULL,
    status TEXT NOT NULL,
    result_text TEXT,
    is_error INTEGER NOT NULL DEFAULT 0,
    error_message TEXT,
    created_at TEXT NOT NULL,
    started_at TEXT,
    finished_at TEXT,
    lease_owner TEXT,
    lease_until TEXT
);

CREATE INDEX IF NOT EXISTS idx_tool_runs_status ON tool_runs(status);

CREATE TABLE IF NOT EXISTS tool_run_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT NOT NULL,
    seq INTEGER NOT NULL,
    kind TEXT NOT NULL,
    stage TEXT,
    message TEXT NOT NULL,
    detail_json TEXT,
    created_at TEXT NOT NULL,
    UNIQUE(run_id, seq)
);

CREATE INDEX IF NOT EXISTS idx_tool_run_events_run ON tool_run_events(run_id, seq);

CREATE TABLE IF NOT EXISTS workflow_runs (
    id TEXT PRIMARY KEY NOT NULL,
    kind TEXT NOT NULL,
    status TEXT NOT NULL,
    context_json TEXT NOT NULL,
    input_json TEXT NOT NULL,
    idempotency_key TEXT,
    current_step_id TEXT,
    result_json TEXT,
    error_message TEXT,
    created_at TEXT NOT NULL,
    finished_at TEXT
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_workflow_idempotency_running
    ON workflow_runs(idempotency_key)
    WHERE idempotency_key IS NOT NULL AND status = 'running';

CREATE TABLE IF NOT EXISTS workflow_run_steps (
    id TEXT PRIMARY KEY NOT NULL,
    workflow_id TEXT NOT NULL,
    step_index INTEGER NOT NULL,
    kind TEXT NOT NULL,
    status TEXT NOT NULL,
    tool_run_id TEXT,
    result_json TEXT,
    created_at TEXT NOT NULL,
    started_at TEXT,
    finished_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_workflow_steps_workflow ON workflow_run_steps(workflow_id, step_index);

CREATE TABLE IF NOT EXISTS workflow_run_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    workflow_id TEXT NOT NULL,
    seq INTEGER NOT NULL,
    kind TEXT NOT NULL,
    stage TEXT,
    message TEXT NOT NULL,
    detail_json TEXT,
    created_at TEXT NOT NULL,
    UNIQUE(workflow_id, seq)
);

CREATE INDEX IF NOT EXISTS idx_workflow_events_workflow ON workflow_run_events(workflow_id, seq);
