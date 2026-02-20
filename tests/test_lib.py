"""
pg_agent Python Library Unit Tests

Run: python -m pytest tests/test_lib.py -v
"""

import os
import sys
import unittest
from unittest.mock import patch, MagicMock

# Add parent directory for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from lib.chat import get_chat_response
from lib.embeddings import get_embedding, get_embeddings_batch


class TestChatRouting(unittest.TestCase):
    """Test that chat provider routing works correctly."""

    def test_unknown_provider_raises(self):
        """Unknown provider should raise ValueError."""
        settings = {'chat_provider': 'nonexistent', 'chat_model': 'test'}
        with self.assertRaises(ValueError) as ctx:
            get_chat_response('hello', [], '', settings)
        self.assertIn('nonexistent', str(ctx.exception))

    @patch('lib.chat._openai_chat', return_value='openai response')
    def test_routes_to_openai(self, mock_fn):
        settings = {'chat_provider': 'openai', 'chat_model': 'gpt-4o-mini'}
        result = get_chat_response('hi', [], '', settings)
        self.assertEqual(result, 'openai response')
        mock_fn.assert_called_once()

    @patch('lib.chat._anthropic_chat', return_value='anthropic response')
    def test_routes_to_anthropic(self, mock_fn):
        settings = {'chat_provider': 'anthropic', 'chat_model': 'claude-3-haiku-20240307'}
        result = get_chat_response('hi', [], '', settings)
        self.assertEqual(result, 'anthropic response')
        mock_fn.assert_called_once()

    @patch('lib.chat._gemini_chat', return_value='gemini response')
    def test_routes_to_gemini(self, mock_fn):
        settings = {'chat_provider': 'gemini', 'chat_model': 'gemini-1.5-flash'}
        result = get_chat_response('hi', [], '', settings)
        self.assertEqual(result, 'gemini response')
        mock_fn.assert_called_once()

    @patch('lib.chat._ollama_chat', return_value='ollama response')
    def test_routes_to_ollama(self, mock_fn):
        settings = {'chat_provider': 'ollama', 'chat_model': 'llama3.1:8b'}
        result = get_chat_response('hi', [], '', settings)
        self.assertEqual(result, 'ollama response')
        mock_fn.assert_called_once()

    def test_default_provider_is_openai(self):
        """Empty settings should default to openai."""
        settings = {}
        with patch('lib.chat._openai_chat', return_value='ok') as mock_fn:
            get_chat_response('hi', [], '', settings)
            mock_fn.assert_called_once()


class TestEmbeddingRouting(unittest.TestCase):
    """Test that embedding provider routing works correctly."""

    def test_unknown_provider_raises(self):
        settings = {'embedding_provider': 'nonexistent', 'embedding_model': 'test'}
        with self.assertRaises(ValueError) as ctx:
            get_embedding('hello', settings)
        self.assertIn('nonexistent', str(ctx.exception))

    @patch('lib.embeddings._openai_embedding', return_value=[0.1, 0.2])
    def test_routes_to_openai(self, mock_fn):
        settings = {'embedding_provider': 'openai', 'embedding_model': 'text-embedding-3-small'}
        result = get_embedding('test', settings)
        self.assertEqual(result, [0.1, 0.2])
        mock_fn.assert_called_once()

    @patch('lib.embeddings._ollama_embedding', return_value=[0.3, 0.4])
    def test_routes_to_ollama(self, mock_fn):
        settings = {'embedding_provider': 'ollama', 'embedding_model': 'nomic-embed-text'}
        result = get_embedding('test', settings)
        self.assertEqual(result, [0.3, 0.4])
        mock_fn.assert_called_once()

    @patch('lib.embeddings._ollama_embedding', return_value=[0.5])
    def test_batch_ollama_sequential(self, mock_fn):
        settings = {'embedding_provider': 'ollama', 'embedding_model': 'nomic-embed-text'}
        result = get_embeddings_batch(['a', 'b'], settings)
        self.assertEqual(len(result), 2)
        self.assertEqual(mock_fn.call_count, 2)

    def test_default_provider_is_openai(self):
        settings = {}
        with patch('lib.embeddings._openai_embedding', return_value=[0.0]) as mock_fn:
            get_embedding('test', settings)
            mock_fn.assert_called_once()


class TestSettingsParsing(unittest.TestCase):
    """Test settings parsing edge cases."""

    def test_system_prompt_default(self):
        """Settings without system_prompt should use default."""
        settings = {'chat_provider': 'openai', 'chat_model': 'gpt-4o-mini'}
        with patch('lib.chat._openai_chat', return_value='ok') as mock_fn:
            get_chat_response('hi', [], '', settings)
            # Verify default system prompt was passed
            call_args = mock_fn.call_args
            self.assertIn('helpful assistant', call_args[0][3])

    def test_custom_system_prompt(self):
        """Custom system prompt should be passed through."""
        settings = {
            'chat_provider': 'openai',
            'chat_model': 'gpt-4o-mini',
            'system_prompt': 'You are a pirate.'
        }
        with patch('lib.chat._openai_chat', return_value='ok') as mock_fn:
            get_chat_response('hi', [], '', settings)
            call_args = mock_fn.call_args
            self.assertEqual(call_args[0][3], 'You are a pirate.')


class TestOllamaModelFallback(unittest.TestCase):
    """Test Ollama model auto-fallback for OpenAI defaults."""

    @patch('lib.chat.requests')
    def test_chat_gpt4o_mini_fallback(self, mock_requests):
        """gpt-4o-mini should fallback to OLLAMA_CHAT_MODEL or llama3.1:8b."""
        mock_response = MagicMock()
        mock_response.json.return_value = {'message': {'content': 'ok'}}
        mock_response.raise_for_status = MagicMock()
        mock_requests.post.return_value = mock_response

        settings = {'chat_provider': 'ollama', 'chat_model': 'gpt-4o-mini'}
        with patch.dict(os.environ, {'OLLAMA_HOST': 'http://localhost:11434'}, clear=False):
            result = get_chat_response('hi', [], '', settings)

        # Verify the model sent to Ollama is NOT gpt-4o-mini
        call_json = mock_requests.post.call_args[1]['json']
        self.assertNotEqual(call_json['model'], 'gpt-4o-mini')

    @patch('lib.embeddings.requests')
    def test_embedding_default_fallback(self, mock_requests):
        """text-embedding-3-small should fallback to nomic-embed-text for Ollama."""
        mock_response = MagicMock()
        mock_response.json.return_value = {'embedding': [0.1, 0.2, 0.3]}
        mock_response.raise_for_status = MagicMock()
        mock_requests.post.return_value = mock_response

        settings = {
            'embedding_provider': 'ollama',
            'embedding_model': 'text-embedding-3-small'
        }
        with patch.dict(os.environ, {'OLLAMA_HOST': 'http://localhost:11434'}, clear=False):
            result = get_embedding('test', settings)

        call_json = mock_requests.post.call_args[1]['json']
        self.assertNotEqual(call_json['model'], 'text-embedding-3-small')


if __name__ == '__main__':
    unittest.main()
