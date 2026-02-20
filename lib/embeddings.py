"""pg_agent Embedding Providers.

Supports: OpenAI, Gemini, Voyage, Ollama
"""

import os
import requests
from typing import List


def get_embedding(text: str, settings: dict) -> List[float]:
    """Get embedding for text using configured provider."""
    provider = settings.get('embedding_provider', 'openai')
    model = settings.get('embedding_model', 'text-embedding-3-small')
    
    if provider == 'openai':
        return _openai_embedding(text, model)
    elif provider == 'gemini':
        return _gemini_embedding(text, model)
    elif provider == 'voyage':
        return _voyage_embedding(text, model)
    elif provider == 'ollama':
        return _ollama_embedding(text, model)
    else:
        raise ValueError(f"Unknown embedding provider: {provider}")


def get_embeddings_batch(texts: List[str], settings: dict) -> List[List[float]]:
    """Get embeddings for multiple texts."""
    provider = settings.get('embedding_provider', 'openai')
    model = settings.get('embedding_model', 'text-embedding-3-small')
    
    if provider == 'openai':
        return _openai_embeddings_batch(texts, model)
    elif provider == 'gemini':
        return [_gemini_embedding(t, model) for t in texts]
    elif provider == 'voyage':
        return _voyage_embeddings_batch(texts, model)
    elif provider == 'ollama':
        return [_ollama_embedding(t, model) for t in texts]
    else:
        raise ValueError(f"Unknown embedding provider: {provider}")


def _ollama_embedding(text: str, model: str) -> List[float]:
    host = os.getenv('OLLAMA_HOST', 'http://127.0.0.1:11434').rstrip('/')

    # Common local default for embeddings
    if model == 'text-embedding-3-small':
        model = os.getenv('OLLAMA_EMBEDDING_MODEL', 'nomic-embed-text')

    response = requests.post(
        f"{host}/api/embeddings",
        json={"model": model, "prompt": text},
        timeout=30,
    )
    response.raise_for_status()
    data = response.json()
    if 'embedding' not in data:
        raise ValueError(f"Invalid Ollama embedding response: {data}")
    return data['embedding']


def _openai_embedding(text: str, model: str) -> List[float]:
    from openai import OpenAI
    client = OpenAI(api_key=os.getenv('OPENAI_API_KEY'))
    response = client.embeddings.create(model=model, input=text)
    return response.data[0].embedding


def _openai_embeddings_batch(texts: List[str], model: str) -> List[List[float]]:
    from openai import OpenAI
    client = OpenAI(api_key=os.getenv('OPENAI_API_KEY'))
    response = client.embeddings.create(model=model, input=texts)
    return [item.embedding for item in sorted(response.data, key=lambda x: x.index)]


def _gemini_embedding(text: str, model: str) -> List[float]:
    import google.generativeai as genai
    genai.configure(api_key=os.getenv('GEMINI_API_KEY'))
    
    # Gemini uses different model names
    if model == 'text-embedding-3-small':
        model = 'models/embedding-001'
    
    result = genai.embed_content(model=model, content=text)
    return result['embedding']


def _voyage_embedding(text: str, model: str) -> List[float]:
    import voyageai
    client = voyageai.Client(api_key=os.getenv('VOYAGE_API_KEY'))
    
    # Voyage uses different model names
    if model == 'text-embedding-3-small':
        model = 'voyage-2'
    
    result = client.embed([text], model=model)
    return result.embeddings[0]


def _voyage_embeddings_batch(texts: List[str], model: str) -> List[List[float]]:
    import voyageai
    client = voyageai.Client(api_key=os.getenv('VOYAGE_API_KEY'))
    
    if model == 'text-embedding-3-small':
        model = 'voyage-2'
    
    result = client.embed(texts, model=model)
    return result.embeddings
