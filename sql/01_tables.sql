-- ============================================================================
-- pgagent: Core Tables
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
