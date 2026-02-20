-- ============================================================================
-- pgagent: PostgreSQL Agent Extension
-- Purpose: Initialization and Schema Setup
-- ============================================================================

-- Extension dependencies
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Single unified schema
CREATE SCHEMA IF NOT EXISTS pgagent;

COMMENT ON SCHEMA pgagent IS 'pgagent: Autonomous Agent capabilities for PostgreSQL';
