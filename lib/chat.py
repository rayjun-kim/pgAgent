"""pgagent Chat Providers.

Supports: OpenAI, Anthropic, Gemini, Ollama
"""

import os
import requests
from typing import List, Dict


def get_chat_response(user_message: str, history: List[Dict], context: str, settings: dict) -> str:
    """Get chat response using configured provider."""
    provider = settings.get('chat_provider', 'openai')
    model = settings.get('chat_model', 'gpt-4o-mini')
    system_prompt = settings.get('system_prompt', 'You are a helpful assistant with access to long-term memory.')
    
    if provider == 'openai':
        return _openai_chat(user_message, history, context, system_prompt, model)
    elif provider == 'anthropic':
        return _anthropic_chat(user_message, history, context, system_prompt, model)
    elif provider == 'gemini':
        return _gemini_chat(user_message, history, context, system_prompt, model)
    elif provider == 'ollama':
        return _ollama_chat(user_message, history, context, system_prompt, model)
    else:
        raise ValueError(f"Unknown chat provider: {provider}")


def _openai_chat(user_message: str, history: List[Dict], context: str, system_prompt: str, model: str) -> str:
    from openai import OpenAI
    client = OpenAI(api_key=os.getenv('OPENAI_API_KEY'))
    
    messages = [{"role": "system", "content": system_prompt + context}]
    messages.extend(history)
    messages.append({"role": "user", "content": user_message})
    
    response = client.chat.completions.create(
        model=model,
        messages=messages,
        max_tokens=1024
    )
    return response.choices[0].message.content


def _anthropic_chat(user_message: str, history: List[Dict], context: str, system_prompt: str, model: str) -> str:
    from anthropic import Anthropic
    client = Anthropic(api_key=os.getenv('ANTHROPIC_API_KEY'))
    
    # Anthropic uses different model names
    if model == 'gpt-4o-mini':
        model = 'claude-3-haiku-20240307'
    elif model == 'gpt-4o':
        model = 'claude-3-5-sonnet-20241022'
    
    messages = list(history)
    messages.append({"role": "user", "content": user_message})
    
    response = client.messages.create(
        model=model,
        max_tokens=1024,
        system=system_prompt + context,
        messages=messages
    )
    return response.content[0].text


def _gemini_chat(user_message: str, history: List[Dict], context: str, system_prompt: str, model: str) -> str:
    import google.generativeai as genai
    genai.configure(api_key=os.getenv('GEMINI_API_KEY'))
    
    # Gemini uses different model names
    if model in ('gpt-4o-mini', 'gpt-4o'):
        model = 'gemini-1.5-flash'
    
    gemini_model = genai.GenerativeModel(model, system_instruction=system_prompt + context)
    
    # Convert history format
    chat = gemini_model.start_chat(history=[
        {"role": "user" if m["role"] == "user" else "model", "parts": [m["content"]]}
        for m in history
    ])
    
    response = chat.send_message(user_message)
    return response.text


def _ollama_chat(user_message: str, history: List[Dict], context: str, system_prompt: str, model: str) -> str:
    host = os.getenv('OLLAMA_HOST', 'http://127.0.0.1:11434').rstrip('/')

    # Reasonable local default
    if model in ('gpt-4o-mini', 'gpt-4o'):
        model = os.getenv('OLLAMA_CHAT_MODEL', 'llama3.1:8b')

    messages = [{"role": "system", "content": system_prompt + context}]
    messages.extend(history)
    messages.append({"role": "user", "content": user_message})

    response = requests.post(
        f"{host}/api/chat",
        json={"model": model, "messages": messages, "stream": False},
        timeout=120,
    )
    response.raise_for_status()
    payload = response.json()
    message = payload.get("message", {})
    content = message.get("content")
    if not content:
        raise ValueError(f"Invalid Ollama chat response: {payload}")
    return content
