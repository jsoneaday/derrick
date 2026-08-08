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
    decided_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_pending_hitl_status ON pending_hitl_approvals(status);
CREATE INDEX IF NOT EXISTS idx_pending_hitl_notify ON pending_hitl_approvals(notify_posted, status);
