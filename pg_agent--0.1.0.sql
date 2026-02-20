-- ============================================================================
-- pg_agent for PostgreSQL v0.1.0
-- Generated on 2026-02-19 23:06:39 KST
-- ============================================================================

-- Source: sql/00_init.sql
-- ============================================================================
-- pg_agent: PostgreSQL Agent Extension
-- Purpose: Initialization and Schema Setup
-- ============================================================================

-- Extension dependencies
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Single unified schema
CREATE SCHEMA IF NOT EXISTS pgagent;

COMMENT ON SCHEMA pgagent IS 'pg_agent: Autonomous Agent capabilities for PostgreSQL';

-- Source: sql/01_tables.sql
-- ============================================================================
-- pg_agent: Core Tables
-- Purpose: Memory storage, chunking, and session management
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Table: memory
-- Purpose: Main memory storage (Vector + FTS)
-- ----------------------------------------------------------------------------
CREATE TABLE pgagent.memory (
    memory_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Content
    content text NOT NULL,
    embedding vector,
    
    -- Metadata
    importance float DEFAULT 0.7 CHECK (importance >= 0 AND importance <= 1),
    category text DEFAULT 'other',
    source text DEFAULT 'user' CHECK (source IN ('user', 'agent', 'system')),
    
    -- Full-text search (auto-generated)
    tsv tsvector GENERATED ALWAYS AS (to_tsvector('english', content)) STORED,
    
    -- Extra data
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- Indexes
CREATE INDEX idx_memory_category ON pgagent.memory(category);
CREATE INDEX idx_memory_tsv ON pgagent.memory USING GIN(tsv);
CREATE INDEX idx_memory_created ON pgagent.memory(created_at DESC);

-- Vector index (HNSW for better performance)
CREATE INDEX idx_memory_embedding ON pgagent.memory 
    USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);

COMMENT ON TABLE pgagent.memory IS 'Core memory storage with vector embeddings and FTS';

-- ----------------------------------------------------------------------------
-- Table: chunk
-- Purpose: Document chunks for large content
-- ----------------------------------------------------------------------------
CREATE TABLE pgagent.chunk (
    chunk_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    memory_id uuid NOT NULL REFERENCES pgagent.memory(memory_id) ON DELETE CASCADE,
    
    -- Chunk content
    chunk_index int NOT NULL,
    content text NOT NULL,
    embedding vector,
    
    -- Line tracking
    start_line int,
    end_line int,
    
    -- Deduplication hash
    hash text NOT NULL,
    
    -- FTS
    tsv tsvector GENERATED ALWAYS AS (to_tsvector('english', content)) STORED,
    
    created_at timestamptz NOT NULL DEFAULT now(),
    
    UNIQUE (memory_id, chunk_index)
);

-- Indexes
CREATE INDEX idx_chunk_memory ON pgagent.chunk(memory_id);
CREATE INDEX idx_chunk_tsv ON pgagent.chunk USING GIN(tsv);
CREATE INDEX idx_chunk_embedding ON pgagent.chunk 
    USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);

COMMENT ON TABLE pgagent.chunk IS 'Document chunks with embeddings for large content';

-- ----------------------------------------------------------------------------
-- Table: embedding_cache
-- Purpose: Cache embeddings to avoid redundant API calls
-- ----------------------------------------------------------------------------
CREATE TABLE pgagent.embedding_cache (
    hash text PRIMARY KEY,
    embedding vector NOT NULL,
    model text DEFAULT 'text-embedding-3-small',
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_cache_created ON pgagent.embedding_cache(created_at DESC);

COMMENT ON TABLE pgagent.embedding_cache IS 'Embedding cache for deduplication';

-- ----------------------------------------------------------------------------
-- Table: session
-- Purpose: Session-scoped memory (Conversation History)
-- ----------------------------------------------------------------------------
CREATE TABLE pgagent.session (
    session_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Session key (e.g., 'user:123:conversation:456')
    key text UNIQUE NOT NULL,
    
    -- Session context
    context jsonb DEFAULT '{}'::jsonb,
    
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_session_key ON pgagent.session(key);
CREATE INDEX idx_session_updated ON pgagent.session(updated_at DESC);

COMMENT ON TABLE pgagent.session IS 'Session-scoped memory for conversations';

-- Source: sql/02_functions.sql
-- ============================================================================
-- pg_agent: Core Functions
-- Purpose: Main API functions for memory storage and retrieval
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Function: should_capture
-- Purpose: Determine if content should be auto-captured as memory
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pgagent.should_capture(p_text text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    -- Length checks
    IF length(p_text) < 10 OR length(p_text) > 500 THEN
        RETURN false;
    END IF;

    -- Skip injected context
    IF p_text ~* '<relevant-memories>' OR p_text ~* '<[a-z]+>.*</[a-z]+>' THEN
        RETURN false;
    END IF;

    -- Skip common acknowledgments
    IF p_text ~* '^(ok|okay|yes|no|sure|thanks|thank you|got it|understood)$' THEN
        RETURN false;
    END IF;

    -- Personal preferences and facts
    IF p_text ~* 'remember|prefer|hate|love|like|want|need|always|never|important' THEN
        RETURN true;
    END IF;

    -- Decisions
    IF p_text ~* 'decided|will use|going to|plan to' THEN
        RETURN true;
    END IF;

    -- Entities (phone, email, names)
    IF p_text ~* '\+\d{10,}' OR  -- Phone numbers
       p_text ~* '[\w.-]+@[\w.-]+\.\w+' OR -- Emails
       p_text ~* 'my [a-z]+ is|is called|named' THEN
        RETURN true;
    END IF;

    RETURN false;
END;
$$;

COMMENT ON FUNCTION pgagent.should_capture IS 'Determine if text should be auto-captured as memory';

-- ----------------------------------------------------------------------------
-- Function: detect_category
-- Purpose: Auto-categorize memory content
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pgagent.detect_category(p_text text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_text ~* 'prefer|like|love|hate|want|favorite' THEN
        RETURN 'preference';
    END IF;
    
    IF p_text ~* 'decided|will use|plan to|going to' THEN
        RETURN 'decision';
    END IF;
    
    IF p_text ~* '\+\d{10,}|@[\w.-]+\.\w+|is called|named|works at|lives in' THEN
        RETURN 'entity';
    END IF;
    
    IF p_text ~* 'is|are|has|have|was|were' THEN
        RETURN 'fact';
    END IF;
    
    RETURN 'other';
END;
$$;

COMMENT ON FUNCTION pgagent.detect_category IS 'Auto-categorize memory content';

-- ----------------------------------------------------------------------------
-- Function: hash_text
-- Purpose: Generate SHA256 hash
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pgagent.hash_text(p_text text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT encode(digest(p_text, 'sha256'), 'hex');
$$;

-- ----------------------------------------------------------------------------
-- Function: store
-- Purpose: Store content as memory with auto-categorization
-- Usage: SELECT pgagent.store('User prefers dark mode', embedding_vector);
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pgagent.store(
    p_content text,
    p_embedding vector DEFAULT NULL,
    p_source text DEFAULT 'user',
    p_importance float DEFAULT 0.7,
    p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
    v_memory_id uuid;
    v_category text;
    v_hash text;
BEGIN
    -- Auto-detect category
    v_category := pgagent.detect_category(p_content);
    v_hash := pgagent.hash_text(p_content);
    
    -- Check for duplicate
    SELECT memory_id INTO v_memory_id
    FROM pgagent.memory
    WHERE pgagent.hash_text(content) = v_hash;
    
    IF v_memory_id IS NOT NULL THEN
        -- Update existing memory
        UPDATE pgagent.memory
        SET 
            embedding = COALESCE(p_embedding, embedding),
            importance = GREATEST(importance, p_importance),
            metadata = metadata || p_metadata
        WHERE memory_id = v_memory_id;
        
        RETURN v_memory_id;
    END IF;
    
    -- Insert new memory
    INSERT INTO pgagent.memory (
        content, embedding, category, source, importance, metadata
    ) VALUES (
        p_content, p_embedding, v_category, p_source, p_importance, p_metadata
    ) RETURNING memory_id INTO v_memory_id;
    
    -- Cache embedding if provided
    IF p_embedding IS NOT NULL THEN
        INSERT INTO pgagent.embedding_cache (hash, embedding)
        VALUES (v_hash, p_embedding)
        ON CONFLICT (hash) DO NOTHING;
    END IF;
    
    RETURN v_memory_id;
END;
$$;

COMMENT ON FUNCTION pgagent.store IS 'Store content as memory with auto-categorization';

-- ----------------------------------------------------------------------------
-- Function: get_cached_embedding
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pgagent.get_cached_embedding(p_text text)
RETURNS vector
LANGUAGE sql
STABLE
AS $$
    SELECT embedding
    FROM pgagent.embedding_cache
    WHERE hash = pgagent.hash_text(p_text);
$$;

-- ----------------------------------------------------------------------------
-- Function: session_get
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pgagent.session_get(p_key text)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(context, '{}'::jsonb)
    FROM pgagent.session
    WHERE key = p_key;
$$;

-- ----------------------------------------------------------------------------
-- Function: session_set
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pgagent.session_set(p_key text, p_context jsonb)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO pgagent.session (key, context, updated_at)
    VALUES (p_key, p_context, now())
    ON CONFLICT (key) 
    DO UPDATE SET 
        context = p_context,
        updated_at = now();
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: session_append
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pgagent.session_append(p_key text, p_context jsonb)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO pgagent.session (key, context, updated_at)
    VALUES (p_key, p_context, now())
    ON CONFLICT (key) 
    DO UPDATE SET 
        context = pgagent.session.context || p_context,
        updated_at = now();
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: session_delete
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pgagent.session_delete(p_key text)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows bigint;
BEGIN
    DELETE FROM pgagent.session WHERE key = p_key;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows > 0;
END;
$$;

-- Source: sql/03_hybrid_search.sql
-- ============================================================================
-- pg_agent: Hybrid Search
-- Purpose: Combined vector similarity + FTS search
-- ============================================================================

-- Function: search_vector
CREATE OR REPLACE FUNCTION pgagent.search_vector(
    p_embedding vector,
    p_limit int DEFAULT 10,
    p_min_similarity float DEFAULT 0.5
)
RETURNS TABLE (
    memory_id uuid,
    content text,
    category text,
    source text,
    score float
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        m.memory_id,
        m.content,
        m.category,
        m.source,
        (1 - (m.embedding <=> p_embedding))::float AS score
    FROM pgagent.memory m
    WHERE m.embedding IS NOT NULL
      AND (1 - (m.embedding <=> p_embedding)) >= p_min_similarity
    ORDER BY m.embedding <=> p_embedding
    LIMIT p_limit;
END;
$$;

-- Function: search_fts
CREATE OR REPLACE FUNCTION pgagent.search_fts(
    p_query text,
    p_limit int DEFAULT 10
)
RETURNS TABLE (
    memory_id uuid,
    content text,
    category text,
    source text,
    score float
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_tsquery tsquery;
BEGIN
    v_tsquery := websearch_to_tsquery('english', p_query);
    
    RETURN QUERY
    SELECT 
        m.memory_id,
        m.content,
        m.category,
        m.source,
        ts_rank(m.tsv, v_tsquery)::float AS score
    FROM pgagent.memory m
    WHERE m.tsv @@ v_tsquery
    ORDER BY score DESC
    LIMIT p_limit;
END;
$$;

-- Function: search (Hybrid)
CREATE OR REPLACE FUNCTION pgagent.search(
    p_query text,
    p_embedding vector DEFAULT NULL,
    p_limit int DEFAULT 10,
    p_vector_weight float DEFAULT 0.7,
    p_text_weight float DEFAULT 0.3,
    p_min_similarity float DEFAULT 0.3
)
RETURNS TABLE (
    memory_id uuid,
    content text,
    category text,
    source text,
    score float,
    vector_score float,
    text_score float
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_embedding IS NULL THEN
        RETURN QUERY
        SELECT 
            f.memory_id,
            f.content,
            f.category,
            f.source,
            f.score,
            0::float AS vector_score,
            f.score AS text_score
        FROM pgagent.search_fts(p_query, p_limit) f;
        RETURN;
    END IF;

    RETURN QUERY
    WITH vector_results AS (
        SELECT 
            v.memory_id,
            v.content,
            v.category,
            v.source,
            v.score AS vec_score
        FROM pgagent.search_vector(p_embedding, p_limit * 2, p_min_similarity) v
    ),
    fts_results AS (
        SELECT 
            f.memory_id,
            f.content,
            f.category,
            f.source,
            f.score AS txt_score
        FROM pgagent.search_fts(p_query, p_limit * 2) f
    ),
    combined AS (
        SELECT 
            COALESCE(v.memory_id, f.memory_id) AS memory_id,
            COALESCE(v.content, f.content) AS content,
            COALESCE(v.category, f.category) AS category,
            COALESCE(v.source, f.source) AS source,
            COALESCE(v.vec_score, 0) AS vec_score,
            COALESCE(f.txt_score, 0) AS txt_score
        FROM vector_results v
        FULL OUTER JOIN fts_results f ON v.memory_id = f.memory_id
    )
    SELECT 
        c.memory_id,
        c.content,
        c.category,
        c.source,
        (p_vector_weight * c.vec_score + p_text_weight * c.txt_score)::float AS score,
        c.vec_score::float AS vector_score,
        c.txt_score::float AS text_score
    FROM combined c
    ORDER BY score DESC
    LIMIT p_limit;
END;
$$;

COMMENT ON FUNCTION pgagent.search IS 'Hybrid search combining vector similarity and FTS';

-- Function: search_chunks
CREATE OR REPLACE FUNCTION pgagent.search_chunks(
    p_embedding vector,
    p_limit int DEFAULT 10,
    p_min_similarity float DEFAULT 0.5
)
RETURNS TABLE (
    chunk_id uuid,
    memory_id uuid,
    content text,
    start_line int,
    end_line int,
    score float
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        c.chunk_id,
        c.memory_id,
        c.content,
        c.start_line,
        c.end_line,
        (1 - (c.embedding <=> p_embedding))::float AS score
    FROM pgagent.chunk c
    WHERE c.embedding IS NOT NULL
      AND (1 - (c.embedding <=> p_embedding)) >= p_min_similarity
    ORDER BY c.embedding <=> p_embedding
    LIMIT p_limit;
END;
$$;

-- Function: find_similar
CREATE OR REPLACE FUNCTION pgagent.find_similar(
    p_memory_id uuid,
    p_limit int DEFAULT 5
)
RETURNS TABLE (
    memory_id uuid,
    content text,
    category text,
    score float
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_embedding vector;
BEGIN
    SELECT embedding INTO v_embedding
    FROM pgagent.memory
    WHERE memory_id = p_memory_id;
    
    IF v_embedding IS NULL THEN
        RETURN;
    END IF;
    
    RETURN QUERY
    SELECT 
        m.memory_id,
        m.content,
        m.category,
        (1 - (m.embedding <=> v_embedding))::float AS score
    FROM pgagent.memory m
    WHERE m.memory_id != p_memory_id
      AND m.embedding IS NOT NULL
    ORDER BY m.embedding <=> v_embedding
    LIMIT p_limit;
END;
$$;

-- Source: sql/04_chunking.sql
-- ============================================================================
-- pg_agent: Chunking
-- Purpose: Text chunking and document storage
-- ============================================================================

-- Function: chunk_text
CREATE OR REPLACE FUNCTION pgagent.chunk_text(
    p_content text,
    p_max_tokens int DEFAULT 500,
    p_overlap_tokens int DEFAULT 50
)
RETURNS TABLE (
    chunk_index int,
    content text,
    start_line int,
    end_line int,
    hash text
)
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_lines text[];
    v_max_chars int;
    v_overlap_chars int;
    v_current_text text := '';
    v_current_start int := 1;
    v_chunk_idx int := 0;
    v_line_num int;
    v_line text;
BEGIN
    -- Approximate: 1 token ≈ 4 characters
    v_max_chars := GREATEST(128, p_max_tokens * 4);
    v_overlap_chars := GREATEST(0, p_overlap_tokens * 4);
    
    v_lines := string_to_array(p_content, E'\n');
    
    FOR v_line_num IN 1..array_length(v_lines, 1) LOOP
        v_line := v_lines[v_line_num];
        
        IF length(v_current_text) + length(v_line) + 1 > v_max_chars AND length(v_current_text) > 0 THEN
            chunk_index := v_chunk_idx;
            content := v_current_text;
            start_line := v_current_start;
            end_line := v_line_num - 1;
            hash := pgagent.hash_text(v_current_text);
            RETURN NEXT;
            
            v_chunk_idx := v_chunk_idx + 1;
            
            IF v_overlap_chars > 0 AND length(v_current_text) > v_overlap_chars THEN
                v_current_text := right(v_current_text, v_overlap_chars);
                v_current_start := v_line_num - 1;
            ELSE
                v_current_text := '';
                v_current_start := v_line_num;
            END IF;
        END IF;
        
        IF length(v_current_text) > 0 THEN
            v_current_text := v_current_text || E'\n' || v_line;
        ELSE
            v_current_text := v_line;
        END IF;
    END LOOP;
    
    IF length(v_current_text) > 0 THEN
        chunk_index := v_chunk_idx;
        content := v_current_text;
        start_line := v_current_start;
        end_line := array_length(v_lines, 1);
        hash := pgagent.hash_text(v_current_text);
        RETURN NEXT;
    END IF;
END;
$$;

-- Function: store_document
CREATE OR REPLACE FUNCTION pgagent.store_document(
    p_content text,
    p_chunk_embeddings vector[] DEFAULT NULL,
    p_title text DEFAULT NULL,
    p_source text DEFAULT 'user',
    p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
    v_memory_id uuid;
    v_chunk record;
    v_chunk_idx int := 0;
BEGIN
    INSERT INTO pgagent.memory (
        content, source, metadata, category
    ) VALUES (
        COALESCE(p_title, left(p_content, 100)),
        p_source,
        p_metadata || jsonb_build_object('type', 'document', 'full_content_length', length(p_content)),
        'fact'
    ) RETURNING memory_id INTO v_memory_id;
    
    FOR v_chunk IN SELECT * FROM pgagent.chunk_text(p_content) LOOP
        INSERT INTO pgagent.chunk (
            memory_id, chunk_index, content, start_line, end_line, hash, embedding
        ) VALUES (
            v_memory_id,
            v_chunk.chunk_index,
            v_chunk.content,
            v_chunk.start_line,
            v_chunk.end_line,
            v_chunk.hash,
            CASE 
                WHEN p_chunk_embeddings IS NOT NULL AND v_chunk_idx < array_length(p_chunk_embeddings, 1)
                THEN p_chunk_embeddings[v_chunk_idx + 1]
                ELSE NULL
            END
        );
        v_chunk_idx := v_chunk_idx + 1;
    END LOOP;
    
    RETURN v_memory_id;
END;
$$;

-- Function: delete_memory
CREATE OR REPLACE FUNCTION pgagent.delete_memory(p_memory_id uuid)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows bigint;
BEGIN
    DELETE FROM pgagent.memory WHERE memory_id = p_memory_id;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows > 0;
END;
$$;

-- Function: clear_all
CREATE OR REPLACE FUNCTION pgagent.clear_all()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    TRUNCATE pgagent.memory CASCADE;
    TRUNCATE pgagent.session;
    TRUNCATE pgagent.embedding_cache;
END;
$$;

-- Function: stats
CREATE OR REPLACE FUNCTION pgagent.stats()
RETURNS TABLE (
    total_memories bigint,
    total_chunks bigint,
    total_sessions bigint,
    cached_embeddings bigint,
    memories_with_vector bigint,
    category_counts jsonb
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT
        (SELECT count(*) FROM pgagent.memory)::bigint,
        (SELECT count(*) FROM pgagent.chunk)::bigint,
        (SELECT count(*) FROM pgagent.session)::bigint,
        (SELECT count(*) FROM pgagent.embedding_cache)::bigint,
        (SELECT count(*) FROM pgagent.memory WHERE embedding IS NOT NULL)::bigint,
        COALESCE(
            (SELECT jsonb_object_agg(category, cnt) 
             FROM (SELECT category, count(*) as cnt FROM pgagent.memory GROUP BY category) sub),
            '{}'::jsonb
        );
END;
$$;

-- Source: sql/05_settings.sql
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

