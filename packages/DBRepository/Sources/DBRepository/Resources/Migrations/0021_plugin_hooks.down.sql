ALTER TABLE factory_sessions DROP COLUMN instruction_plugin_id;
ALTER TABLE plugin_versions DROP COLUMN skills_json;
ALTER TABLE plugins DROP COLUMN hooks_json;
ALTER TABLE plugins DROP COLUMN is_system;
