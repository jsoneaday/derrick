ALTER TABLE plugins ADD COLUMN is_system INTEGER NOT NULL DEFAULT 0;
ALTER TABLE plugins ADD COLUMN hooks_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE plugin_versions ADD COLUMN skills_json TEXT NOT NULL DEFAULT '{}';
ALTER TABLE factory_sessions ADD COLUMN instruction_plugin_id TEXT;
