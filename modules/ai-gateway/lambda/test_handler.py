"""Unit tests for pure-logic functions in the ai-gateway Lambda handler.

These tests cover functions that have no AWS dependencies and can run
without credentials or network access.
"""
import json
import os
import sys
from unittest.mock import MagicMock, patch

# Satisfy module-level os.environ reads before importing handler
os.environ.update(
    {
        "TABLE_API_KEYS": "test-api-keys",
        "TABLE_RATE": "test-rate",
        "TABLE_COST_LOG": "test-cost-log",
        "TABLE_CACHE": "test-cache",
        "PRIMARY_MODEL": "anthropic.claude-3-haiku-20240307-v1:0",
    }
)

# Stub boto3 so module-level client/resource creation doesn't contact AWS
with patch("boto3.resource", return_value=MagicMock()), patch(
    "boto3.client", return_value=MagicMock()
):
    sys.path.insert(0, os.path.dirname(__file__))
    import handler  # noqa: E402

import pytest


# ---------------------------------------------------------------------------
# calculate_cost
# ---------------------------------------------------------------------------
class TestCalculateCost:
    def test_known_model_haiku(self):
        # (1000 * 0.00025 + 1000 * 0.00125) / 1000 = 0.0015
        cost = handler.calculate_cost("anthropic.claude-3-haiku-20240307-v1:0", 1000, 1000)
        assert cost == pytest.approx(0.0015)

    def test_unknown_model_uses_default_pricing(self):
        # default: input=0.001, output=0.005
        # (1000 * 0.001 + 1000 * 0.005) / 1000 = 0.006
        cost = handler.calculate_cost("unknown.model-xyz", 1000, 1000)
        assert cost == pytest.approx(0.006)

    def test_zero_tokens(self):
        assert handler.calculate_cost("anthropic.claude-3-haiku-20240307-v1:0", 0, 0) == 0.0

    def test_embedding_model_has_no_output_cost(self):
        # titan-embed: input=0.00002, output=0.0
        # (1000 * 0.00002 + 0) / 1000 = 0.00002
        cost = handler.calculate_cost("amazon.titan-embed-text-v2:0", 1000, 0)
        assert cost == pytest.approx(0.00002)

    def test_output_only_charges_output_rate(self):
        # Verify input and output contributions are independent
        cost_in = handler.calculate_cost("anthropic.claude-3-haiku-20240307-v1:0", 1000, 0)
        cost_out = handler.calculate_cost("anthropic.claude-3-haiku-20240307-v1:0", 0, 1000)
        cost_both = handler.calculate_cost("anthropic.claude-3-haiku-20240307-v1:0", 1000, 1000)
        assert cost_both == pytest.approx(cost_in + cost_out)


# ---------------------------------------------------------------------------
# _build_cache_key
# ---------------------------------------------------------------------------
class TestBuildCacheKey:
    def test_deterministic(self):
        model = "anthropic.claude-3-haiku-20240307-v1:0"
        messages = [{"role": "user", "content": "hello"}]
        params = {"max_tokens": 100}
        assert handler._build_cache_key(model, messages, params) == handler._build_cache_key(
            model, messages, params
        )

    def test_different_content_produces_different_keys(self):
        params = {}
        k1 = handler._build_cache_key("m", [{"role": "user", "content": "hello"}], params)
        k2 = handler._build_cache_key("m", [{"role": "user", "content": "world"}], params)
        assert k1 != k2

    def test_different_models_produce_different_keys(self):
        messages = [{"role": "user", "content": "hi"}]
        k1 = handler._build_cache_key("model-a", messages, {})
        k2 = handler._build_cache_key("model-b", messages, {})
        assert k1 != k2

    def test_model_name_is_lowercased(self):
        messages = [{"role": "user", "content": "hi"}]
        k1 = handler._build_cache_key("ANTHROPIC.CLAUDE", messages, {})
        k2 = handler._build_cache_key("anthropic.claude", messages, {})
        assert k1 == k2

    def test_returns_64_char_hex_string(self):
        key = handler._build_cache_key("m", [], {})
        assert len(key) == 64
        int(key, 16)  # raises ValueError if not valid hex


# ---------------------------------------------------------------------------
# _extract_api_key
# ---------------------------------------------------------------------------
class TestExtractApiKey:
    def test_bearer_token(self):
        event = {"headers": {"Authorization": "Bearer sk-test-1234"}}
        assert handler._extract_api_key(event) == "sk-test-1234"

    def test_bearer_header_case_insensitive(self):
        event = {"headers": {"authorization": "BEARER sk-test-5678"}}
        assert handler._extract_api_key(event) == "sk-test-5678"

    def test_x_api_key_header(self):
        event = {"headers": {"x-api-key": "mykey-abc"}}
        assert handler._extract_api_key(event) == "mykey-abc"

    def test_bearer_takes_priority_over_x_api_key(self):
        event = {"headers": {"Authorization": "Bearer bearer-key", "x-api-key": "xkey"}}
        assert handler._extract_api_key(event) == "bearer-key"

    def test_missing_headers_returns_empty(self):
        assert handler._extract_api_key({}) == ""

    def test_no_auth_header_returns_empty(self):
        event = {"headers": {"Content-Type": "application/json"}}
        assert handler._extract_api_key(event) == ""


# ---------------------------------------------------------------------------
# _build_bedrock_body
# ---------------------------------------------------------------------------
class TestBuildBedrockBody:
    def test_claude_separates_system_message(self):
        model = "anthropic.claude-3-haiku-20240307-v1:0"
        messages = [
            {"role": "system", "content": "You are helpful."},
            {"role": "user", "content": "Hi"},
        ]
        _, body_bytes = handler._build_bedrock_body(model, messages, {})
        body = json.loads(body_bytes)
        assert body["anthropic_version"] == "bedrock-2023-05-31"
        assert body["system"] == "You are helpful."
        assert body["messages"] == [{"role": "user", "content": "Hi"}]

    def test_claude_no_system_omits_system_key(self):
        model = "anthropic.claude-3-haiku-20240307-v1:0"
        messages = [{"role": "user", "content": "Hello"}]
        _, body_bytes = handler._build_bedrock_body(model, messages, {})
        body = json.loads(body_bytes)
        assert "system" not in body

    def test_llama_builds_prompt_with_role_tags(self):
        model = "meta.llama3-8b-instruct-v1:0"
        messages = [{"role": "user", "content": "What is 2+2?"}]
        _, body_bytes = handler._build_bedrock_body(model, messages, {})
        body = json.loads(body_bytes)
        assert "prompt" in body
        assert "user" in body["prompt"]
        assert "What is 2+2?" in body["prompt"]

    def test_titan_text_uses_textGenerationConfig(self):
        model = "amazon.titan-text-express-v1"
        messages = [{"role": "user", "content": "Hello"}]
        _, body_bytes = handler._build_bedrock_body(model, messages, {"max_tokens": 256})
        body = json.loads(body_bytes)
        assert "inputText" in body
        assert body["textGenerationConfig"]["maxTokenCount"] == 256

    def test_content_type_is_always_json(self):
        for model in [
            "anthropic.claude-3-haiku-20240307-v1:0",
            "meta.llama3-8b-instruct-v1:0",
            "amazon.titan-text-express-v1",
        ]:
            ct, _ = handler._build_bedrock_body(model, [], {})
            assert ct == "application/json"


# ---------------------------------------------------------------------------
# _parse_bedrock_response
# ---------------------------------------------------------------------------
class TestParseBedrockResponse:
    def test_claude_response(self):
        model = "anthropic.claude-3-haiku-20240307-v1:0"
        raw = json.dumps(
            {
                "content": [{"type": "text", "text": "Hello!"}],
                "usage": {"input_tokens": 10, "output_tokens": 5},
            }
        ).encode()
        text, in_tok, out_tok = handler._parse_bedrock_response(model, raw)
        assert text == "Hello!"
        assert in_tok == 10
        assert out_tok == 5

    def test_llama_response(self):
        model = "meta.llama3-8b-instruct-v1:0"
        raw = json.dumps(
            {
                "generation": "42",
                "prompt_token_count": 8,
                "generation_token_count": 2,
            }
        ).encode()
        text, in_tok, out_tok = handler._parse_bedrock_response(model, raw)
        assert text == "42"
        assert in_tok == 8
        assert out_tok == 2

    def test_titan_text_response(self):
        model = "amazon.titan-text-express-v1"
        raw = json.dumps(
            {
                "results": [{"outputText": "Nice.", "tokenCount": 3}],
                "inputTextTokenCount": 7,
            }
        ).encode()
        text, in_tok, out_tok = handler._parse_bedrock_response(model, raw)
        assert text == "Nice."
        assert in_tok == 7
        assert out_tok == 3

    def test_unknown_model_returns_zero_tokens(self):
        model = "unknown.model"
        raw = json.dumps({"result": "ok"}).encode()
        _, in_tok, out_tok = handler._parse_bedrock_response(model, raw)
        assert in_tok == 0
        assert out_tok == 0
