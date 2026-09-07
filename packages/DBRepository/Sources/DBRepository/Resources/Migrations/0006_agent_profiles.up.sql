CREATE TABLE IF NOT EXISTS agent_profiles (
    id TEXT PRIMARY KEY NOT NULL,
    display_name TEXT NOT NULL,
    handle TEXT NOT NULL UNIQUE,
    instructions TEXT NOT NULL DEFAULT '',
    model_json TEXT NOT NULL,
    thinking_json TEXT,
    rag_json TEXT NOT NULL,
    is_enabled INTEGER NOT NULL DEFAULT 1,
    is_builtin INTEGER NOT NULL DEFAULT 0,
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_agent_profiles_handle ON agent_profiles(handle);
CREATE INDEX IF NOT EXISTS idx_agent_profiles_sort ON agent_profiles(sort_order, display_name);
