#!/usr/bin/env python3
"""
pgagent Web GUI Server
Usage: python gui/server.py [--port 8000] [--db DATABASE_URL]
"""

import os
import sys
import argparse
from contextlib import asynccontextmanager
from typing import Optional, List
from dotenv import load_dotenv

from fastapi import FastAPI, HTTPException
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

# Add parent directory for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from lib.database import Database
from lib.embeddings import get_embedding
from lib.chat import get_chat_response

load_dotenv()

# Global database connection
db: Optional[Database] = None

# Conversation history per session
conversations = {}


@asynccontextmanager
async def lifespan(app: FastAPI):
    global db
    db_url = os.getenv('DATABASE_URL', 'postgresql://localhost:5432/postgres')
    db = Database(db_url)
    yield
    db.close()


app = FastAPI(title="pgagent", lifespan=lifespan)

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# Models
class ChatRequest(BaseModel):
    message: str
    session_id: str = "default"


class ChatResponse(BaseModel):
    response: str
    memories_used: List[dict] = []
    memory_saved: bool = False


class SettingRequest(BaseModel):
    key: str
    value: str


class MemoryRequest(BaseModel):
    content: str
    source: str = "user"


# API Routes
@app.get("/api/health")
def health():
    return {"status": "ok", "service": "pgagent
"}


@app.get("/api/settings")
def get_settings():
    return db.get_all_settings()


@app.post("/api/settings")
def update_setting(req: SettingRequest):
    db.set_setting(req.key, req.value)
    return {"success": True, "key": req.key, "value": req.value}


@app.get("/api/stats")
def get_stats():
    return db.get_stats()


@app.get("/api/memories")
def get_memories(limit: int = 50, offset: int = 0):
    memories = db.get_memories(limit, offset)
    return {"memories": memories, "limit": limit, "offset": offset}


@app.delete("/api/memories/{memory_id}")
def delete_memory(memory_id: str):
    success = db.delete_memory(memory_id)
    if not success:
        raise HTTPException(status_code=404, detail="Memory not found")
    return {"success": True}


@app.post("/api/memories")
def store_memory(req: MemoryRequest):
    settings = db.get_all_settings()
    try:
        embedding = get_embedding(req.content, settings)
    except Exception:
        embedding = None
    
    memory_id = db.store(req.content, embedding, source=req.source)
    return {"memory_id": str(memory_id)}


@app.post("/api/chat", response_model=ChatResponse)
def chat(req: ChatRequest):
    global conversations
    settings = db.get_all_settings()
    
    # Get or create conversation history
    if req.session_id not in conversations:
        conversations[req.session_id] = []
    history = conversations[req.session_id]
    
    # Get embedding for search
    try:
        query_embedding = get_embedding(req.message, settings)
    except Exception as e:
        query_embedding = None
    
    # Search memories
    memories = []
    if query_embedding:
        memories = db.search(
            req.message, 
            query_embedding, 
            limit=int(settings.get('search_limit', 5))
        )
    else:
        memories = db.search_fts(req.message, limit=int(settings.get('search_limit', 5)))
    
    # Build context
    context = ""
    if memories:
        context = "\n<relevant-memories>\n"
        for m in memories:
            context += f"- [{m['category']}] {m['content']}\n"
        context += "</relevant-memories>\n"
    
    # Get chat response
    try:
        response = get_chat_response(req.message, history, context, settings)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    
    # Update history
    history.append({"role": "user", "content": req.message})
    history.append({"role": "assistant", "content": response})
    
    # Keep history manageable
    if len(history) > 20:
        conversations[req.session_id] = history[-20:]
    
    # Auto-capture
    memory_saved = False
    if settings.get('auto_capture', True) and db.should_capture(req.message):
        try:
            embedding = query_embedding or get_embedding(req.message, settings)
            db.store(req.message, embedding, source='user')
            memory_saved = True
        except Exception:
            pass
    
    return ChatResponse(
        response=response,
        memories_used=[dict(m) for m in memories[:3]] if memories else [],
        memory_saved=memory_saved
    )


@app.post("/api/chat/clear")
def clear_chat(session_id: str = "default"):
    if session_id in conversations:
        del conversations[session_id]
    return {"success": True}


# Static files (frontend)
static_dir = os.path.join(os.path.dirname(__file__), "static")
if os.path.exists(static_dir):
    app.mount("/static", StaticFiles(directory=static_dir), name="static")


@app.get("/")
def index():
    return FileResponse(os.path.join(static_dir, "index.html"))


if __name__ == "__main__":
    import uvicorn
    
    parser = argparse.ArgumentParser(description='pgagent
 Web GUI')
    parser.add_argument('--port', type=int, default=8000, help='Port to run on')
    parser.add_argument('--host', default='127.0.0.1', help='Host to bind to')
    parser.add_argument('--db', help='Database URL')
    args = parser.parse_args()
    
    if args.db:
        os.environ['DATABASE_URL'] = args.db
    
    print(f"🧠 pgagent
 Web GUI starting on http://{args.host}:{args.port}")
    uvicorn.run(app, host=args.host, port=args.port)
