# pgAgent 

is a SQL extension + Python interface (CLI/Web) project for storing and searching **agent memory (long-term memory)** inside PostgreSQL. 

- Memory is stored in `pgagent.memory`, `pgagent.chunk`, and `pgagent.session` tables. 
- Search works as a hybrid of **vector similarity (pgvector)** and **full-text search (FTS)**. 
- Supported LLM/embedding providers include OpenAI, Anthropic, Gemini, Voyage, and **Ollama (local model)**. 

--- 

## Table of Contents 

1. [Project Purpose](#1-Project-Purpose) 
2. [Components](#2-Components) 
3. [Requirements](#3-Requirements) 
4. [Quick Installation](#4-Quick-Installation) 
5. [Ollama Integration](#5-ollama-Integration) 
6. [How to Run](#6-How-to-Run) 
7. [How-to Encyclopedia](#7-How-to-Use Encyclopedia) 
   - [SQL API Full Reference](#71-sql-api-full-reference) 
   - [REST API Full Reference](#72-rest-api-full-reference) 
   - [CLI Command Reference](#73-cli-command-reference) 
   - [How to Use Web GUI](#74-how-to-use-web-gui) 
   - [Python Library Reference](#75-python-library-reference) 
   - [Guide by practical scenario](#76-Guide by practical-scenario) 
8. [Settings key](#8-Settings-key) 
9. [Testing/verification](#9-Testing-verification) 
10. [Troubleshooting](#10-Troubleshooting) 
11. [Development memo](#11-Development-memo) 
12. [License](#license) 

--- 

## 1) Project purpose 

General agent frameworks are difficult to track because their memory is distributed across external vector DBs/files. `pgagent` manages memory as PostgreSQL standard objects, enabling the following: 

- Immediately check the memory status with SQL 
- Reuse PostgreSQL operating tools such as transaction/index/backup 
- Directly correct incorrectly stored memory with UPDATE/DELETE 

--- 

## 2) Components 

### SQL Extension 
- Schema: `pgagent` 
- Core functions: `store`, `search`, `search_fts`, `search_vector`, `search_chunks`, `find_similar`, `store_document`, `chunk_text`, `stats`, `session_*`, etc. 

### Python library 
- `lib/database.py`: DB wrapper (supports automatic reconnection) 
- `lib/embeddings.py`: Embedding provider routing (OpenAI, Gemini, Voyage, Ollama) 
- `lib/chat.py`: Chat model provider routing (OpenAI, Anthropic, Gemini, Ollama) 

### Execution interface 
- CLI: `cli/chat.py` 
- Web GUI (FastAPI + static HTML): `gui/server.py`, `gui/static/index.html` 

--- 

## 3) Requirements 

- Ubuntu/Linux or macOS 
- PostgreSQL 14+ (document example is 16) 
- pgvector 
- Python 3.10+ 

--- 

## 4) Quick installation 

### 4.1 Install PostgreSQL + pgvector 

```bash 
# Ubuntu 
apt -y update 
apt -y install postgresql postgresql-contrib 
apt -y install postgresql-16-pgvector 

# macOS (Homebrew) 
brew install postgresql@16 pgvector 
``` 

### 4.2 Start PostgreSQL and prepare for connection 

```bash 
service postgresql start # Linux 
brew services start postgresql@16 # macOS 

sudo -u postgres psql -c "SELECT version();" 
``` 

### 4.3 Install extensions 

```bash 
# Check dependent extensions
sudo -u postgres psql -d postgres -c "CREATE EXTENSION IF NOT EXISTS vector;" 
sudo -u postgres psql -d postgres -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;" 

# Place the pgagent installation file 
make install 

# Create the extension in the database 
sudo -u postgres psql -d postgres -c "CREATE EXTENSION IF NOT EXISTS pgagent;" 
``` 

### 4.4 Python environment 

```bash 
python3 -m venv .venv 
source .venv/bin/activate 
pip install -r requirements.txt 
cp .env.example .env 
``` 

Minimum environment variables: 

```env 
DATABASE_URL=postgresql://postgres@localhost:5432/postgres 
OLLAMA_HOST=http://127.0.0.1:11434 
``` 

--- 

## 5) Ollama integration 

### 5.1 Installation/execution 

```bash 
ollama serve 
``` 

### 5.2 Model preparation 

```bash 
ollama pull llama3.1:8b # Chat 
ollama pull nomic-embed-text # Embedding (768 dimensions) 
``` 

### 5.3 Connection check 

```bash 
curl http://127.0.0.1:11434/api/tags 
``` 

### 5.4 Switch settings 

```sql 
SELECT pgagent.set_setting('chat_provider', '"ollama"'); 
SELECT pgagent.set_setting('chat_model', '"llama3.1:8b"'); 
SELECT pgagent.set_setting('embedding_provider', '"ollama"'); 
SELECT pgagent.set_setting('embedding_model', '"nomic-embed-text"'); 
``` 

--- 

## 6) How to run 

### 6.1 CLI 

```bash 
source .venv/bin/activate 
python cli/chat.py --db postgresql://postgres@localhost:5432/postgres 
``` 

### 6.2 Web GUI 

```bash 
source .venv/bin/activate 
python gui/server.py --host 0.0.0.0 --port 8000 
``` 

Browser: `http://localhost:8000` 

--- 

## 7) How to use Encyclopedia 

### 7.1 SQL API full reference 

#### Memory storage 

##### `pgagent.store()` 

Stores memory. The category is automatically detected. 

```sql 
-- Default usage 
SELECT pgagent.store('User prefers dark mode'); 

-- Including embeddings 
SELECT pgagent.store( 
  'I like coffee', -- Content 
  '[0.1,0.2,...]'::vector, -- Embedding (any dimension is OK) 
  'user', -- Source 
  0.9, -- Importance (0.0~1.0) 
  '{"tag":"preference"}'::jsonb -- Metadata 
); 

-- Automatically merge duplicate saves (based on SHA256 hash) 
-- If the same content is stored again, the one with higher importance is kept 
SELECT pgagent.store('I like coffee', NULL, 'user', 1.0); 
``` 

**Returns:** `uuid` (memory_id) 

##### `pgagent.store_document()` 

Automatically chunks and saves a long document. 

```sql 
-- Save document (automatically calls chunk_text)























-- Return: true (delete successfully) / false (none) 
-- Connected chunks are also deleted in CASCADE 
``` 

##### `pgagent.clear_all()` 

```sql 
-- ⚠️ Delete all memory, session, and embedding cache 
SELECT pgagent.clear_all(); 
``` 

##### Manage directly with SQL 

```sql 
-- Query only specific categories 
SELECT * FROM pgagent.memory WHERE category = 'preference'; 

-- Modify specific memory contents 
UPDATE pgagent.memory 
SET content = 'modified contents', importance = 1.0 
WHERE memory_id = 'uuid-here'; 

-- Delete old memory 
DELETE FROM pgagent.memory 
WHERE created_at < now() - interval '30 days' 
  AND importance < 0.5; 

-- Count by category 
SELECT category, count(*) FROM pgagent.memory GROUP BY category; 
``` 

--- 

#### Automatic Classification Tool 

##### `pgagent.should_capture()` 

Decides if text is worth storing in memory. 

```sql 
SELECT pgagent.should_capture('I prefer dark mode'); -- true 
SELECT pgagent.should_capture('ok'); -- false (too short) 
SELECT pgagent.should_capture('my email is a@b.com'); -- true (entity) 
SELECT pgagent.should_capture('I decided to use Python'); -- true (decision) 
``` 

**Rules:** 
- Less than 10 characters or more than 500 characters → `false` 
- Contains XML tags → `false` (Prevents injected context) 
- Simple responses like "ok", "yes", "thanks" → `false` 
- Prefer, like, love, hate, remember, etc. → `true` 
- Decided, will use, plan to, etc. → `true` 
- Phone number, email, name patterns → `true` 

##### `pgagent.detect_category()` 

Automatically categorizes text into categories. 

```sql 
SELECT pgagent.detect_category('I prefer dark mode'); -- 'preference' 
SELECT pgagent.detect_category('I decided to use Redis'); -- 'decision' 
SELECT pgagent.detect_category('my email is test@x.com'); -- 'entity' 
SELECT pgagent.detect_category('PostgreSQL supports JSONB'); -- 'fact' 
SELECT pgagent.detect_category('Hello'); -- 'other' 
``` 

--- 

#### Session (conversation context) 

Key-value based JSON context storage. 

```sql 
-- Create/overwrite session 
SELECT pgagent.session_set('user:123', '{"topic":"postgres","mood":"good"}'::jsonb); 

-- Get session 
SELECT pgagent.session_get('user:123'); 
-- → {"topic": "postgres", "mood": "good"} 

-- Add/merge keys to session (keep existing keys, add new keys) 
SELECT pgagent.session_append('user:123', '{"step": 3}'::jsonb); 
SELECT pgagent.session_get('user:123'); 
-- → {"topic": "postgres", "mood": "good", "step": 3} 

-- Delete session 
-- → true (deleted) 
``` 

--- 

#### Text processing 


Split long text into chunks. 

```sql
SELECT * FROM pgagent.chunk_text( 
  'Long text...', -- Original text 
  500, -- Max tokens per chunk (default 500, 1 token≈4 characters) 
  50 -- Overlap tokens (default 50) 
); 
``` 

**Return columns:** `chunk_index`, `content`, `start_line`, `end_line`, `hash` 

##### `pgagent.hash_text()` 

```sql 
SELECT pgagent.hash_text('Hello World'); 
-- → SHA256 hash (hex string) 
``` 

##### `pgagent.get_cached_embedding()` 

Retrieves a previously saved embedding by hash. 

```sql 
SELECT pgagent.get_cached_embedding('Hello World'); 
-- → vector or NULL 
``` 

--- 

#### Statistics 

##### `pgagent.stats()` 

```sql 
SELECT * FROM pgagent.stats(); 
``` 

| Column | Description | 
|---|---| 
| `total_memories` | Total memory | 
| `total_chunks` | Total chunks | 
| `total_sessions` | Total sessions | 
| `cached_embeddings` | Number of cached embeddings | 
| `memories_with_vector` | Number of memory with vector | 
| `category_counts` | Counts by category (JSON) | 

--- 

#### Settings management 

```sql 
-- Retrieve individual settings 
SELECT pgagent.get_setting('chat_provider'); 

-- Retrieve all settings 
SELECT pgagent.get_all_settings(); 

-- Change settings (values ​​are wrapped in JSON format) 
SELECT pgagent.set_setting('chat_provider', '"ollama"'); 
SELECT pgagent.set_setting('search_limit', '10'); 
SELECT pgagent.set_setting('auto_capture', 'true'); 

-- Reset settings 
SELECT pgagent.reset_settings(); 
``` 

--- 

### 7.2 REST API Full Reference 

This is the API provided by the Web GUI server (`gui/server.py`). 

#### Health check 

```bash 
curl http://localhost:8000/api/health 
# → {"status":"ok","service":"pgagent"} 
``` 

#### Chat 

```bash 
# Send a chat 
curl -X POST http://localhost:8000/api/chat \ 
  -H "Content-Type: application/json" \ 
  -d '{"message":"Hello", "session_id":"user1"}' 

# Response: 
# { 
# "response": "Hello! How may I help you?", 
# "memories_used": [...], 
# "memory_saved": true 
# } 

# Clear chat history 
curl -X POST "http://localhost:8000/api/chat/clear?session_id=user1" 
``` 

#### Settings 

```bash 
# View all settings 
curl http://localhost:8000/api/settings 
# → {"chat_provider":"ollama", "chat_model":"llama3.1:8b", ...} 

# Change settings 
curl -X POST http://localhost:8000/api/settings \ 


```bash 
# View memory list 
curl "http://localhost:8000/api/memories?limit=10&offset=0"
# → {"memories":[...], "limit":10, "offset":0} 

# Manually save memory 
curl -X POST http://localhost:8000/api/memories \ 
  -H "Content-Type: application/json" \ 
  -d '{"content":"Important information","source":"manual"}' 
# → {"memory_id":"uuid-here"} 

# Delete memory 
curl -X DELETE http://localhost:8000/api/memories/{memory_id} 
``` 

#### Statistics 

```bash 
curl http://localhost:8000/api/stats 
# → {"total_memories":42, "total_chunks":15, "total_sessions":3, ...} 
``` 

--- 

### 7.3 CLI Command Reference 

```bash 
python cli/chat.py --db postgresql://postgres@localhost:5432/postgres 
``` 

Commands available during the conversation: 

| Command | Description | Example | 
|---|---|---| 
| `stats` | Print memory/chunk/session statistics | `stats` | 
| `clear` | Clear current conversation history | `clear` | 
| `setting key=value` | Change settings in real time | `setting chat_model=llama3. 1:8b` | 
| `quit` / `exit` / `q` | Exit CLI | `quit` | 

**Example conversation flow:** 

``` 
🧠 pgagent CLI 
📡 Chat: ollama / llama3. 1:8b 
🔢 Embedding: ollama / nomic-embed-text 
---------------------------------------- 

👤 You: I like coffee 
🤖 Assistant: So you like coffee! What kind of coffee do you prefer? 
   💾 (memory saved) 

👤 You: Americano is my favorite 
🤖 Assistant: You like Americano! I'll remember that information. 
   💾 (memory saved) 

👤 You: What did I say I like? 
🤖 Assistant: You said you like coffee, especially Americano! 

👤 You: stats 
📊 Stats: 2 memories, 0 chunks, 0 sessions 

👤 You: setting search_limit=10 
⚙️ Set search_limit = 10 

👤 You: quit 
👋 Goodbye! 
``` 

--- 

### 7.4 How to use Web GUI 

#### Chat tab 
- Send a message by pressing the **Send** button or the `Enter` key 
- Automatically search for related memories and pass them to LLM as context 
- Display `📚 N memories used` / `💾 saved` at the bottom of the message 
- Automatically save memories if the `should_capture` condition is met 

#### Settings tab 
- Select **Chat provider**: OpenAI / Anthropic / Gemini / Ollama 
- Select **Chat model**: Model name by provider 
- Select **Embedding provider** 
- Select **Embedding model** 
- Real-time changes such as **Search limit**, **Minimum similarity**, **Automatic capture** 
- Changes are immediately reflected in the DB 

#### Memory tab 
- **Statistics**: Displays the total number of memories/chunks/sessions 
- **Memory list**: Check categories, sources, and contents 
- **Delete**: Delete each memory individually with the 🗑️ button next to it 

--- 

### 7.5 Python library reference 

You can use `pgagent` directly from the code. 

```python 
from lib.embeddings import get_embedding, get_embeddings_batch 
from lib.chat import get_chat_response 

# Connect to DB (automatic reconnection supported) 
db = Database("postgresql://postgres@localhost:5432/postgres")

# Get/Change Settings 
settings = db.get_all_settings() 
db.set_setting("chat_provider", "ollama") 

# Create embeddings 
embedding = get_embedding("Like coffee", settings) 
# → [0.123, -0.456, ...] (dimensions vary by model) 

# Batch embeddings 
embeddings = get_embeddings_batch(["text1", "text2"], settings) 

# Store in memory 
memory_id = db.store("Like coffee", embedding, source="user", importance=0.9) 

# Hybrid search 
results = db.search("Prefer drinks", embedding, limit=5, min_similarity=0.3) 
for r in results: 
    print(f"[{r['category']}] {r['content']} (score: {r['score']:.2f})") 

# FTS-only search (No embedding required) 
results = db.search_fts("Coffee", limit=5) 

# Automatic capture judgment 
if db.should_capture("User said he prefers Python"): 
    db.store("User prefers Python", embedding) 

# Statistics 
stats = db.get_stats() 
print(f"Memory {stats['total_memories']}") 

# Chat (memory linking) 
context = "\n".join(f"- {r['content']}" for r in results) 
response = get_chat_response( 
    "What are my drink preferences?", 
    history=[], # Previous conversation 
    context=context, # Searched memory 
    settings=settings # Provider/model settings 
) 
print(response) 

# Summary 
db.close() 
``` 

--- 

### 7.6 Guide by practical scenario 

#### Scenario 1: User preference/profile management 

```sql 
-- Save preferences 
SELECT pgagent.store('User has turned on dark mode 'preference', NULL, 'user', 0.9); 
SELECT pgagent.store('User email: user@example.com', NULL, 'user', 1.0); 

-- Search user preferences 
SELECT content, category, importance 
FROM pgagent.memory 
WHERE category = 'preference' 
ORDER BY importance DESC; 

-- Search entities (contacts, etc.) 
SELECT * FROM pgagent.search_fts('email', 5); 
``` 

#### Scenario 2: Building a document/knowledge base 

```sql 
-- Store documents (automatic chunking) 
SELECT pgagent.store_document( 
  pg_read_file('/tmp/guide.md'), 
  NULL, 
  'Setup Guide', 
  'document' 
); 

-- Checking chunks 
SELECT c.chunk_index, c.content, c.start_line, c.end_line 
FROM pgagent.chunk c 
JOIN pgagent.memory m ON c.memory_id = m.memory_id 
WHERE m.content = 'Setup Guide'; 

-- Search by chunk (embedding required) 
-- After creating the embedding in Python: 
SELECT * FROM pgagent.search_chunks('[0.1,0.2,...]'::vector, 5, 0.5); 
``` 























```bash 
python3 -m unittest tests.test_lib -v 
# Ran 15 tests in 0.003s — OK 
``` 

### 9.3 API health check 

```bash 
curl http://127.0.0.1:8000/api/health 
``` 

### 9.4 Direct check query

```sql 
SELECT count(*) FROM pgagent.memory; 
SELECT * FROM pgagent.get_all_settings(); 
SELECT * FROM pgagent.stats(); 
``` 

--- 

## 10) Troubleshooting 

### `extension "vector" is not available` 
- Missing pgvector package installation 
- Check if `postgresql-<major>-pgvector` is installed 

### `permission denied` or authentication error 
- Recheck `DATABASE_URL` user/host 
- If in local peer authentication environment, run as `postgres` user 

### Ollama connection failure 
- Check if `ollama serve` is running 
- Check `OLLAMA_HOST` value (default: `http://127.0.0.1:11434`) 
- Check if `curl $OLLAMA_HOST/api/tags` is successful 

### Embedding dimension mismatch warning 
- Search is not possible if the dimensions of the old and new vectors are different when changing the provider 
- Recommended to re-save after `pgagent.clear_all()` 

### Model name error 
- Enter the exact model name installed with `ollama list` 

--- 

## 11) Development memo 

- SQL source: `sql/*.sql` 
- Single file for distribution: `pgagent--0.1.0.sql` (generated with Makefile) 
- Regenerate SQL: `make pgagent--0.1.0.sql` 
- Test SQL: `tests/smoke_test.sql` 
- Python tests: `tests/test_lib.py` 

--- 
