# pgAgent 

is a SQL extension + Python interface (CLI/Web) project for storing and searching **agent memory (long-term memory)** inside PostgreSQL. 

- Memory is stored in `pgagent.memory`, `pgagent.chunk`, and `pgagent.session` tables. 
- Search works as a hybrid of **vector similarity (pgvector)** and **full-text search (FTS)**. 
- Supported LLM/embedding providers include OpenAI, Anthropic, Gemini, Voyage, and **Ollama (local model)**. 
