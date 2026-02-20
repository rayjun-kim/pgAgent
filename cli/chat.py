#!/usr/bin/env python3
"""
pgagent CLI Chat
Usage: python cli/chat.py [--db DATABASE_URL]
"""

import os
import sys
import argparse
from dotenv import load_dotenv

# Add parent directory for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from lib.database import Database
from lib.embeddings import get_embedding
from lib.chat import get_chat_response

load_dotenv()


def main():
    parser = argparse.ArgumentParser(description='pgagent CLI Chat')
    parser.add_argument('--db', default=os.getenv('DATABASE_URL', 'postgresql://localhost:5432/postgres'),
                        help='Database connection URL')
    args = parser.parse_args()

    print("🧠 pgagent CLI")
    print("Type 'quit' or 'exit' to end, 'stats' for memory stats")
    print("-" * 40)

    db = Database(args.db)
    settings = db.get_all_settings()
    
    print(f"📡 Chat: {settings.get('chat_provider', 'openai')} / {settings.get('chat_model', 'gpt-4o-mini')}")
    print(f"🔢 Embedding: {settings.get('embedding_provider', 'openai')} / {settings.get('embedding_model', 'text-embedding-3-small')}")
    print("-" * 40)

    conversation_history = []
    
    while True:
        try:
            user_input = input("\n👤 You: ").strip()
        except (KeyboardInterrupt, EOFError):
            print("\n\n👋 Goodbye!")
            break

        if not user_input:
            continue
            
        if user_input.lower() in ('quit', 'exit', 'q'):
            print("\n👋 Goodbye!")
            break
            
        if user_input.lower() == 'stats':
            stats = db.get_stats()
            print(f"\n📊 Stats: {stats['total_memories']} memories, {stats['total_chunks']} chunks, {stats['total_sessions']} sessions")
            continue
            
        if user_input.lower() == 'clear':
            conversation_history = []
            print("\n🗑️  Conversation cleared")
            continue
            
        if user_input.lower().startswith('setting '):
            parts = user_input[8:].split('=', 1)
            if len(parts) == 2:
                key, value = parts[0].strip(), parts[1].strip()
                db.set_setting(key, value)
                print(f"\n⚙️  Set {key} = {value}")
            else:
                print("\n⚙️  Usage: setting key=value")
            continue

        # Get embedding for search
        try:
            query_embedding = get_embedding(user_input, settings)
        except Exception as e:
            print(f"\n⚠️  Embedding error: {e}")
            query_embedding = None

        # Search memories
        memories = []
        if query_embedding:
            memories = db.search(user_input, query_embedding, limit=int(settings.get('search_limit', 5)))
        else:
            # Fallback to FTS only
            memories = db.search_fts(user_input, limit=int(settings.get('search_limit', 5)))

        # Build context from memories
        context = ""
        if memories:
            context = "\n<relevant-memories>\n"
            for m in memories:
                context += f"- [{m['category']}] {m['content']}\n"
            context += "</relevant-memories>\n"

        # Get chat response
        try:
            response = get_chat_response(
                user_input, 
                conversation_history, 
                context, 
                settings
            )
            print(f"\n🤖 Assistant: {response}")
            
            # Update conversation history
            conversation_history.append({"role": "user", "content": user_input})
            conversation_history.append({"role": "assistant", "content": response})
            
            # Keep history manageable
            if len(conversation_history) > 20:
                conversation_history = conversation_history[-20:]
                
        except Exception as e:
            print(f"\n⚠️  Chat error: {e}")
            continue

        # Auto-capture if enabled
        if settings.get('auto_capture', True):
            if db.should_capture(user_input):
                try:
                    embedding = get_embedding(user_input, settings) if query_embedding else None
                    db.store(user_input, embedding, source='user')
                    print("   💾 (memory saved)")
                except Exception as e:
                    pass  # Silent fail for auto-capture

    db.close()


if __name__ == '__main__':
    main()
