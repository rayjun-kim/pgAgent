import os, json
from lib.database import Database
from lib.embeddings import get_embedding, get_embeddings_batch
from lib.chat import get_chat_response

DB_URL = os.getenv('DATABASE_URL', 'postgresql:///postgres')
settings = {
    'embedding_provider': 'ollama',
    'embedding_model': 'nomic-embed-text',
    'chat_provider': 'ollama',
    'chat_model': 'llama3.2:1b',
    'system_prompt': 'You are a concise assistant.'
}

db = Database(DB_URL)
print('connected')

db.execute('SELECT pgagent.clear_all()')
for k,v in settings.items():
    db.set_setting(k, v)
print('settings_updated', db.execute_one("SELECT pgagent.get_setting('chat_model')::text AS v")['v'])

texts = [
    'I prefer dark mode in all apps',
    'My project uses PostgreSQL with pgvector extension',
    'Deploy window is every Tuesday at 09:00 UTC'
]
embs = get_embeddings_batch(texts, settings)
print('emb_dims', len(embs[0]), len(embs[1]), len(embs[2]))

ids=[]
for t,e in zip(texts, embs):
    mid = db.store(t, e, source='user', importance=0.9)
    ids.append(str(mid))
print('stored_ids', ids)

q = 'what database and extension are used?'
qemb = get_embedding(q, settings)
res_hybrid = db.search(q, qemb, limit=3)
res_fts = db.search_fts('PostgreSQL pgvector', limit=3)
print('hybrid_top', res_hybrid[0]['content'] if res_hybrid else None)
print('fts_top', res_fts[0]['content'] if res_fts else None)

vec_only = db.execute('SELECT * FROM pgagent.search_vector(%s::vector, 3, 0.1)', (f"[{','.join(map(str,qemb))}]",))
print('vector_count', len(vec_only))

sim = db.execute('SELECT * FROM pgagent.find_similar(%s::uuid, 2)', (ids[0],))
print('similar_count', len(sim))

doc = 'Line 1 architecture\nLine 2 pgvector details\nLine 3 rollout plan\nLine 4 observability\nLine 5 backup policy\nLine 6 contact info'
doc_id = db.execute_one('SELECT pgagent.store_document(%s, NULL, %s, %s, %s::jsonb) AS id', (doc, 'Runbook', 'document', '{"type":"runbook"}'))['id']
chunks = db.execute('SELECT chunk_id, content FROM pgagent.chunk WHERE memory_id = %s::uuid ORDER BY chunk_index', (str(doc_id),))
chunk_embs = get_embeddings_batch([c['content'] for c in chunks], settings)
for c,e in zip(chunks, chunk_embs):
    db.execute('UPDATE pgagent.chunk SET embedding=%s::vector WHERE chunk_id=%s::uuid', (f"[{','.join(map(str,e))}]", str(c['chunk_id'])))
print('doc_id', doc_id)

chunk_emb = get_embedding('pgvector details', settings)
chunk_res = db.execute('SELECT * FROM pgagent.search_chunks(%s::vector, 5, 0.1)', (f"[{','.join(map(str,chunk_emb))}]",))
print('chunk_hits', len(chunk_res))

# session lifecycle
db.execute("SELECT pgagent.session_set('e2e:session', '{\"task\":\"integration\"}'::jsonb)")
db.execute("SELECT pgagent.session_append('e2e:session', '{\"status\":\"ok\"}'::jsonb)")
sess = db.execute_one("SELECT pgagent.session_get('e2e:session') as ctx")['ctx']
print('session_ctx', sess)

context = '\n<relevant-memories>\n' + '\n'.join(f"- [{m['category']}] {m['content']}" for m in res_hybrid) + '\n</relevant-memories>\n'
chat = get_chat_response('What do you remember about our stack?', [], context, settings)
print('chat_prefix', chat[:120].replace('\n',' '))

stats = db.get_stats()
print('stats', json.dumps(stats, default=str))
print('recent_count', len(db.get_memories(limit=10)))

db.execute("SELECT pgagent.session_delete('e2e:session')")
db.close()
print('done')