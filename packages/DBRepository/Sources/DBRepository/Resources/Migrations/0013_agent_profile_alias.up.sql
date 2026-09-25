ALTER TABLE agent_profiles ADD COLUMN alias TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_profiles_alias ON agent_profiles(alias) WHERE alias IS NOT NULL;
