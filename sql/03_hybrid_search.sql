-- ============================================================================
-- pgagent: Hybrid Search
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
