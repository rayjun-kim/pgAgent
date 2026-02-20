-- ============================================================================
-- pg_agent: Settings
-- Purpose: Configuration management
-- ============================================================================

-- Table: settings
CREATE TABLE pgagent.settings (
    key text PRIMARY KEY,
    value jsonb NOT NULL,
    description text,
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- Default settings
INSERT INTO pgagent.settings (key, value, description) VALUES
    ('embedding_provider', '"openai"', 'Embedding provider: openai, gemini, voyage, ollama'),
    ('embedding_model', '"text-embedding-3-small"', 'Embedding model name'),
    ('embedding_dims', '1536', 'Embedding dimensions'),
    ('chat_provider', '"openai"', 'Chat provider: openai, anthropic, gemini, ollama'),
    ('chat_model', '"gpt-4o-mini"', 'Chat model name'),
    ('system_prompt', '"You are a helpful assistant with access to long-term memory."', 'Default system prompt'),
    ('auto_capture', 'true', 'Auto-capture important messages'),
    ('search_limit', '5', 'Default number of memories to retrieve'),
    ('min_similarity', '0.3', 'Minimum similarity threshold for search')
ON CONFLICT (key) DO NOTHING;

COMMENT ON TABLE pgagent.settings IS 'Configuration key-value store';

-- Function: get_setting
CREATE OR REPLACE FUNCTION pgagent.get_setting(p_key text)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT value FROM pgagent.settings WHERE key = p_key;
$$;

-- Function: set_setting
CREATE OR REPLACE FUNCTION pgagent.set_setting(p_key text, p_value jsonb)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO pgagent.settings (key, value, updated_at)
    VALUES (p_key, p_value, now())
    ON CONFLICT (key) DO UPDATE SET
        value = p_value,
        updated_at = now();
END;
$$;

-- Function: get_all_settings
CREATE OR REPLACE FUNCTION pgagent.get_all_settings()
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT jsonb_object_agg(key, value) FROM pgagent.settings;
$$;

-- Function: reset_settings
CREATE OR REPLACE FUNCTION pgagent.reset_settings()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM pgagent.settings;
    INSERT INTO pgagent.settings (key, value, description) VALUES
        ('embedding_provider', '"openai"', 'Embedding provider: openai, gemini, voyage, ollama'),
        ('embedding_model', '"text-embedding-3-small"', 'Embedding model name'),
        ('embedding_dims', '1536', 'Embedding dimensions'),
        ('chat_provider', '"openai"', 'Chat provider: openai, anthropic, gemini, ollama'),
        ('chat_model', '"gpt-4o-mini"', 'Chat model name'),
        ('system_prompt', '"You are a helpful assistant with access to long-term memory."', 'Default system prompt'),
        ('auto_capture', 'true', 'Auto-capture important messages'),
        ('search_limit', '5', 'Default number of memories to retrieve'),
        ('min_similarity', '0.3', 'Minimum similarity threshold for search');
END;
$$;
