-- ============================================================================
-- pgagent: Core Functions
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
