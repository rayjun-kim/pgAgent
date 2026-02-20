# pgagent

This is the full English operational guide for **pgagent**.

`pgagent` is a PostgreSQL extension + Python toolkit that lets you store, search, and manage an AI agent's long-term memory directly in PostgreSQL.

---

## Contents

1. [What pgagent is](#1-what-pgagent-is)
2. [When to use it](#2-when-to-use-it)
3. [System architecture](#3-system-architecture)
4. [Capabilities checklist](#4-capabilities-checklist)
5. [Compatibility and prerequisites](#5-compatibility-and-prerequisites)
6. [Install PostgreSQL and pgvector (Ubuntu)](#6-install-postgresql-and-pgvector-ubuntu)
7. [Install Ollama and local models](#7-install-ollama-and-local-models)
8. [Build and install extension](#8-build-and-install-extension)
9. [Python environment setup](#9-python-environment-setup)
10. [Environment variables and provider settings](#10-environment-variables-and-provider-settings)
11. [Deep SQL API reference and practical usage](#11-deep-sql-api-reference-and-practical-usage)
12. [CLI usage in detail](#12-cli-usage-in-detail)
13. [Web GUI usage in detail](#13-web-gui-usage-in-detail)
14. [Python library usage in detail](#14-python-library-usage-in-detail)
15. [Realistic end-to-end runbook](#15-realistic-end-to-end-runbook)
16. [Operational checks and observability](#16-operational-checks-and-observability)
17. [Testing guide](#17-testing-guide)
18. [Common pitfalls and fixes](#18-common-pitfalls-and-fixes)
19. [Project layout](#19-project-layout)
20. [Developer workflow](#20-developer-workflow)

---

## 1) What pgagent is

`pgagent` adds a dedicated `pgagent` schema to your PostgreSQL database with:

- memory storage tables
- search functions
- session context functions
- runtime setting functions
- optional Python interfaces (CLI/Web)

The design goal is simple: **keep agent memory in the same system you already operate**.

---

## 2) When to use it

Use pgagent if you want:

- SQL-level auditability for AI memory
- straightforward backup/recovery (standard PostgreSQL tools)
- direct correction of memory records using SQL
- reduced system complexity (no separate vector DB required)

---

## 3) System architecture

### SQL extension layer (`pgagent` schema)

Main tables:

- `pgagent.memory`
- `pgagent.chunk`
- `pgagent.embedding_cache`
- `pgagent.session`
- `pgagent.settings`

Main function groups:

- storage: `store`, `store_document`, `delete_memory`, `clear_all`
- search: `search`, `search_fts`, `search_vector`, `search_chunks`, `find_similar`
- classification/util: `should_capture`, `detect_category`, `chunk_text`, `hash_text`, `stats`
- session: `session_set`, `session_get`, `session_append`, `session_delete`
- settings: `get_setting`, `set_setting`, `get_all_settings`, `reset_settings`

### Python layer

- `lib/database.py`: convenience DB wrapper
- `lib/embeddings.py`: embedding provider abstraction
- `lib/chat.py`: chat provider abstraction

### User interfaces

- CLI chat: `cli/chat.py`
- Web app: `gui/server.py`

---

## 4) Capabilities checklist

- [x] FTS search in PostgreSQL
- [x] vector similarity search via pgvector
- [x] hybrid ranking (vector + FTS)
- [x] chunked document storage
- [x] cache reusable embeddings
- [x] session-scoped context memory
- [x] provider routing for chat/embedding
- [x] local model operation via Ollama

---

## 5) Compatibility and prerequisites

- OS: Linux/macOS
- PostgreSQL: 14+ (examples use 16)
- Extensions: `vector`, `pgcrypto`
- Python: 3.10+
- Build tooling: `make`, PostgreSQL dev headers

---

## 6) Install PostgreSQL and pgvector (Ubuntu)

```bash
apt -y update
apt -y install postgresql postgresql-contrib
apt -y install postgresql-16-pgvector
apt -y install postgresql-server-dev-all make python3-venv curl
```

Start and verify:

```bash
service postgresql start
pg_isready
sudo -u postgres psql -c "SELECT version();"
```

Expected check:

- `pg_isready` shows `accepting connections`.

---

## 7) Install Ollama and local models

### 7.1 Install Ollama

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

### 7.2 Start service

```bash
ollama serve
```

If running in a non-systemd environment, keep this process alive in a terminal/tmux session.

### 7.3 Pull models

```bash
# Small local chat model
ollama pull llama3.2:1b

# Embedding model
ollama pull nomic-embed-text
```

### 7.4 Verify model registry

```bash
curl -s http://127.0.0.1:11434/api/tags
```

You should see models including `llama3.2:1b` and `nomic-embed-text`.

---

## 8) Build and install extension

From repository root:

```bash
make pgagent--0.1.0.sql
make install
```

Install DB dependencies and extension in target DB:

```bash
sudo -u postgres psql -d postgres -c "CREATE EXTENSION IF NOT EXISTS vector;"
sudo -u postgres psql -d postgres -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"
sudo -u postgres psql -d postgres -c "CREATE EXTENSION IF NOT EXISTS pgagent;"
```

Confirm installation:

```bash
sudo -u postgres psql -d postgres -c "\dx"
sudo -u postgres psql -d postgres -c "\dn+ pgagent"
```

---

## 9) Python environment setup

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
```

Optional but recommended during development:

```bash
pip install pytest
```

---

## 10) Environment variables and provider settings

### 10.1 `.env` baseline

```env
DATABASE_URL=postgresql://postgres@localhost:5432/postgres
OLLAMA_HOST=http://127.0.0.1:11434
```

Other optional keys:

- `OPENAI_API_KEY`
- `ANTHROPIC_API_KEY`
- `GEMINI_API_KEY`
- `VOYAGE_API_KEY`

### 10.2 Configure runtime provider settings inside PostgreSQL

```sql
SELECT pgagent.set_setting('chat_provider', '"ollama"');
SELECT pgagent.set_setting('chat_model', '"llama3.2:1b"');
SELECT pgagent.set_setting('embedding_provider', '"ollama"');
SELECT pgagent.set_setting('embedding_model', '"nomic-embed-text"');
```

Validate settings:

```sql
SELECT pgagent.get_all_settings();
```

---

## 11) Deep SQL API reference and practical usage

## 11.1 `pgagent.store`

Store one memory row.

```sql
SELECT pgagent.store('User prefers dark mode');
```

Extended form:

```sql
SELECT pgagent.store(
  'User likes pour-over coffee',
  '[0.11,0.22,0.33]'::vector,
  'user',
  0.95,
  '{"tag":"preference","scope":"ui"}'::jsonb
);
```

Notes:

- if same content hash already exists, the function merges metadata/importance logic.
- source must satisfy table constraint values.

## 11.2 `pgagent.store_document`

Store long content and auto-create chunks.

```sql
SELECT pgagent.store_document(
  'Line 1\nLine 2\nLine 3\nLine 4',
  NULL,
  'Support transcript #2026-01',
  'document',
  '{"channel":"email"}'::jsonb
);
```

When passing chunk embeddings, provide an array aligned with generated chunks.

## 11.3 Search APIs

### Hybrid (recommended default)

```sql
SELECT *
FROM pgagent.search(
  'dark mode preference',
  '[0.1,0.2,0.3]'::vector,
  10,
  0.7,
  0.3,
  0.3
);
```

### FTS only

```sql
SELECT * FROM pgagent.search_fts('dark mode', 10);
```

### Vector only

```sql
SELECT * FROM pgagent.search_vector('[0.1,0.2,0.3]'::vector, 10, 0.5);
```

### Chunk search

```sql
SELECT * FROM pgagent.search_chunks('[0.1,0.2,0.3]'::vector, 10, 0.5);
```

### Similar memories from memory_id

```sql
SELECT * FROM pgagent.find_similar('00000000-0000-0000-0000-000000000000'::uuid, 5);
```

## 11.4 Session APIs

```sql
SELECT pgagent.session_set('user:42:chat', '{"topic":"billing"}'::jsonb);
SELECT pgagent.session_append('user:42:chat', '{"last_question":"refund status"}'::jsonb);
SELECT pgagent.session_get('user:42:chat');
SELECT pgagent.session_delete('user:42:chat');
```

## 11.5 Utility functions

```sql
SELECT pgagent.should_capture('I prefer short answers.');
SELECT pgagent.detect_category('I decided to use PostgreSQL for memory');
SELECT pgagent.hash_text('sample text');
SELECT pgagent.get_cached_embedding('User prefers dark mode');
SELECT * FROM pgagent.stats();
```

## 11.6 Maintenance

Delete one memory:

```sql
SELECT pgagent.delete_memory('00000000-0000-0000-0000-000000000000'::uuid);
```

Clear all pgagent data:

```sql
SELECT pgagent.clear_all();
```

---

## 12) CLI usage in detail

Run CLI:

```bash
source .venv/bin/activate
python cli/chat.py --db postgresql://postgres@localhost:5432/postgres
```

Recommended workflow:

1. Ask one short question.
2. Ask a second question that depends on previous preference.
3. Verify memory capture by querying `pgagent.memory`.

Verification SQL:

```sql
SELECT memory_id, content, category, source, created_at
FROM pgagent.memory
ORDER BY created_at DESC
LIMIT 20;
```

---

## 13) Web GUI usage in detail

Start server:

```bash
source .venv/bin/activate
python gui/server.py --host 0.0.0.0 --port 8000
```

Open browser:

- `http://localhost:8000`

Practical checks:

1. Send a message with a preference (“I like concise replies”).
2. Send a follow-up (“remember my preference?”).
3. Confirm memory row exists in `pgagent.memory`.
4. Confirm settings applied via `pgagent.get_all_settings()`.

---

## 14) Python library usage in detail

```python
from lib.database import Database
from lib.embeddings import get_embedding
from lib.chat import get_chat_response

db = Database("postgresql://postgres@localhost:5432/postgres")
settings = db.get_all_settings()

# Optionally override runtime settings
# db.set_setting('chat_provider', 'ollama')
# db.set_setting('chat_model', 'llama3.2:1b')

message = "User prefers concise answers"
embedding = get_embedding(message, settings)
memory_id = db.store(message, embedding, metadata={"type": "preference"})

results = db.search("concise answers", embedding, limit=5)
context = "\n".join([row["content"] for row in results]) if results else ""

reply = get_chat_response("How should I answer the user?", [], context, settings)
print("memory_id:", memory_id)
print("reply:", reply)

db.close()
```

---

## 15) Realistic end-to-end runbook

### Step A — install dependencies

- PostgreSQL
- pgvector
- extension files via `make install`
- Python dependencies
- Ollama and models

### Step B — initialize DB features

- `CREATE EXTENSION vector`
- `CREATE EXTENSION pgcrypto`
- `CREATE EXTENSION pgagent`

### Step C — set providers to Ollama

- chat provider/model
- embedding provider/model

### Step D — run interaction

- store direct memory
- store long document
- run hybrid search
- generate response with context

### Step E — verify persistence

```sql
SELECT count(*) FROM pgagent.memory;
SELECT count(*) FROM pgagent.chunk;
SELECT * FROM pgagent.stats();
```

---

## 16) Operational checks and observability

Check extension-level objects:

```bash
sudo -u postgres psql -d postgres -c "\dt pgagent.*"
sudo -u postgres psql -d postgres -c "\df pgagent.*"
```

Check recent memories and categories:

```sql
SELECT category, count(*)
FROM pgagent.memory
GROUP BY category
ORDER BY count(*) DESC;
```

Check stale sessions:

```sql
SELECT key, updated_at
FROM pgagent.session
ORDER BY updated_at ASC
LIMIT 20;
```

---

## 17) Testing guide

Unit tests:

```bash
source .venv/bin/activate
python -m pytest tests/test_lib.py -v
```

SQL smoke test:

```bash
sudo -u postgres psql -d postgres -f tests/smoke_test.sql
```

E2E integration test:

```bash
source .venv/bin/activate
PYTHONPATH=. DATABASE_URL=postgresql://postgres:postgres@localhost:5432/postgres \
python tests/e2e_ollama_postgres.py
```

---

## 18) Common pitfalls and fixes

### 18.1 `required extension "vector" is not installed`

Install package + extension:

```bash
apt -y install postgresql-16-pgvector
```

```sql
CREATE EXTENSION vector;
```

### 18.2 Ollama not reachable

- Ensure `ollama serve` is running.
- Check host/port: `OLLAMA_HOST=http://127.0.0.1:11434`
- Probe endpoint:

```bash
curl -s http://127.0.0.1:11434/api/tags
```

### 18.3 Authentication failures to PostgreSQL

- verify `DATABASE_URL`
- verify postgres `pg_hba.conf` mode in your environment
- test direct connection:

```bash
psql "postgresql://postgres@localhost:5432/postgres" -c "SELECT 1"
```

### 18.4 Search returns nothing

- FTS query may not match stem/tokenization; try simpler keywords.
- Vector query may have incompatible dimensions; use matching model embeddings.
- Lower `min_similarity` threshold.

### 18.5 Session data not updating as expected

- Use the same `session key` consistently.
- `session_append` performs JSONB merge semantics (`||`).

---

## 19) Project layout

```text
pgagent/
├── sql/
│   ├── 00_init.sql
│   ├── 01_tables.sql
│   ├── 02_functions.sql
│   ├── 03_hybrid_search.sql
│   ├── 04_chunking.sql
│   └── 05_settings.sql
├── lib/
│   ├── __init__.py
│   ├── database.py
│   ├── embeddings.py
│   └── chat.py
├── cli/
│   └── chat.py
├── gui/
│   └── server.py
├── tests/
│   ├── smoke_test.sql
│   ├── test_lib.py
│   └── e2e_ollama_postgres.py
├── pgagent.control
├── pgagent--0.1.0.sql
└── README.md
```

---

## 20) Developer workflow

Regenerate extension SQL bundle after SQL changes:

```bash
make pgagent--0.1.0.sql
```

Install into PostgreSQL extension directory:

```bash
make install
```

Recreate extension in DB for rapid local validation:

```bash
sudo -u postgres psql -d postgres -c "DROP EXTENSION IF EXISTS pgagent CASCADE;"
sudo -u postgres psql -d postgres -c "CREATE EXTENSION pgagent;"
```

Run quick quality gate:

```bash
source .venv/bin/activate
python -m pytest tests/test_lib.py -v
sudo -u postgres psql -d postgres -f tests/smoke_test.sql
```
