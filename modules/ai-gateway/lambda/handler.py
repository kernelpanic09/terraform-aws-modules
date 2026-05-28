"""
AI Gateway Lambda handler -- OpenAI-compatible proxy for AWS Bedrock.

Implements:
  - API key validation against DynamoDB
  - Per-key per-minute rate limiting (atomic DynamoDB counter + TTL)
  - Per-key monthly budget enforcement
  - Prompt response caching (SHA-256 keyed, DynamoDB + TTL)
  - Bedrock invocation with primary + fallback model chain
  - Cost accounting (per-model token pricing)
  - OpenAI-compatible response shape (/v1/chat/completions, /v1/embeddings)
  - CloudWatch metric emission for observability
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import time
import uuid
from decimal import Decimal
from typing import Any

import boto3
from boto3.dynamodb.conditions import Attr
from botocore.config import Config
from botocore.exceptions import ClientError

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ---------------------------------------------------------------------------
# Environment variables (injected by Terraform)
# ---------------------------------------------------------------------------
TABLE_API_KEYS    = os.environ["TABLE_API_KEYS"]
TABLE_RATE        = os.environ["TABLE_RATE"]
TABLE_COST_LOG    = os.environ["TABLE_COST_LOG"]
TABLE_CACHE       = os.environ["TABLE_CACHE"]
PRIMARY_MODEL     = os.environ["PRIMARY_MODEL"]
FALLBACK_MODELS   = json.loads(os.environ.get("FALLBACK_MODELS", "[]"))
ENABLE_CACHING    = os.environ.get("ENABLE_CACHING", "true").lower() == "true"
CACHE_TTL         = int(os.environ.get("CACHE_TTL_SECONDS", "3600"))
COST_LOG_TTL_DAYS = int(os.environ.get("COST_LOG_TTL_DAYS", "90"))
NAMESPACE         = os.environ.get("METRIC_NAMESPACE", "AIGateway")

# ---------------------------------------------------------------------------
# AWS clients
# ---------------------------------------------------------------------------
_RETRY_CONFIG = Config(
    retries={"max_attempts": 3, "mode": "adaptive"},
    connect_timeout=5,
    read_timeout=120,
)

dynamodb    = boto3.resource("dynamodb", config=_RETRY_CONFIG)
bedrock     = boto3.client("bedrock-runtime", config=_RETRY_CONFIG)
cloudwatch  = boto3.client("cloudwatch", config=_RETRY_CONFIG)

tbl_keys    = dynamodb.Table(TABLE_API_KEYS)
tbl_rate    = dynamodb.Table(TABLE_RATE)
tbl_cost    = dynamodb.Table(TABLE_COST_LOG)
tbl_cache   = dynamodb.Table(TABLE_CACHE)

# ---------------------------------------------------------------------------
# Model pricing (USD per 1 000 tokens, input / output)
# Source: AWS Bedrock public pricing as of Q1 2026
# ---------------------------------------------------------------------------
MODEL_PRICING: dict[str, dict[str, float]] = {
    # Claude Haiku 4 (2025)
    "anthropic.claude-haiku-4-5-20251001-v1:0": {"input": 0.0008, "output": 0.004},
    # Claude 3.5 Haiku
    "anthropic.claude-3-5-haiku-20241022-v1:0": {"input": 0.0008, "output": 0.004},
    # Claude 3 Haiku
    "anthropic.claude-3-haiku-20240307-v1:0": {"input": 0.00025, "output": 0.00125},
    # Claude 3 Sonnet
    "anthropic.claude-3-sonnet-20240229-v1:0": {"input": 0.003, "output": 0.015},
    # Claude 3.5 Sonnet v2
    "anthropic.claude-3-5-sonnet-20241022-v2:0": {"input": 0.003, "output": 0.015},
    # Claude 3 Opus
    "anthropic.claude-3-opus-20240229-v1:0": {"input": 0.015, "output": 0.075},
    # Llama 3 8B
    "meta.llama3-8b-instruct-v1:0": {"input": 0.0003, "output": 0.0006},
    # Llama 3 70B
    "meta.llama3-70b-instruct-v1:0": {"input": 0.00265, "output": 0.0035},
    # Llama 3.1 8B
    "meta.llama3-1-8b-instruct-v1:0": {"input": 0.00022, "output": 0.00022},
    # Llama 3.1 70B
    "meta.llama3-1-70b-instruct-v1:0": {"input": 0.00099, "output": 0.00099},
    # Amazon Titan Text Express
    "amazon.titan-text-express-v1": {"input": 0.0002, "output": 0.0006},
    # Amazon Titan Text Lite
    "amazon.titan-text-lite-v1": {"input": 0.00015, "output": 0.0002},
    # Amazon Titan Embeddings v2
    "amazon.titan-embed-text-v2:0": {"input": 0.00002, "output": 0.0},
    # Cohere Embed English
    "cohere.embed-english-v3": {"input": 0.0001, "output": 0.0},
}

_DEFAULT_PRICING = {"input": 0.001, "output": 0.005}

# ---------------------------------------------------------------------------
# Helper: emit CloudWatch metrics in batches
# ---------------------------------------------------------------------------
def _emit_metric(metric_name: str, value: float, unit: str = "Count", dimensions: list[dict] | None = None) -> None:
    """Fire-and-forget CloudWatch metric emission. Errors are logged, not raised."""
    try:
        metric: dict[str, Any] = {
            "MetricName": metric_name,
            "Value": value,
            "Unit": unit,
            "Timestamp": time.time(),
        }
        if dimensions:
            metric["Dimensions"] = dimensions
        cloudwatch.put_metric_data(Namespace=NAMESPACE, MetricData=[metric])
    except Exception as exc:  # pylint: disable=broad-except
        logger.warning("Failed to emit metric %s: %s", metric_name, exc)


# ---------------------------------------------------------------------------
# API key validation
# ---------------------------------------------------------------------------
def authorize_request(api_key: str) -> dict[str, Any]:
    """
    Look up the API key in DynamoDB.

    Returns the key record dict on success.
    Raises PermissionError (401) if not found or disabled.
    """
    if not api_key or len(api_key) < 8:
        raise PermissionError("Missing or malformed API key.")

    try:
        resp = tbl_keys.get_item(Key={"api_key": api_key})
    except ClientError as exc:
        logger.error("DynamoDB get_item error: %s", exc)
        raise RuntimeError("Failed to validate API key.") from exc

    item = resp.get("Item")
    if not item:
        _emit_metric("AuthFailures", 1)
        raise PermissionError("Invalid API key.")

    if not item.get("enabled", True):
        _emit_metric("AuthFailures", 1)
        raise PermissionError("API key is disabled.")

    return item


# ---------------------------------------------------------------------------
# Rate limiting
# ---------------------------------------------------------------------------
def check_rate_limit(api_key: str, rpm_limit: int) -> None:
    """
    Enforce per-key per-minute rate limit using atomic DynamoDB counter.

    The counter key is   "<api_key>#<epoch-minute>".
    TTL is set to 90 seconds so DynamoDB auto-cleans old counters.

    Raises RateLimitError (429) if the limit is exceeded.
    """
    if rpm_limit <= 0:
        return  # unlimited

    epoch_minute = int(time.time() // 60)
    counter_key  = f"{api_key}#{epoch_minute}"
    ttl          = int(time.time()) + 90  # 90-second TTL covers the full minute window

    try:
        resp = tbl_rate.update_item(
            Key={"counter_key": counter_key},
            UpdateExpression="ADD #cnt :one SET #ttl = if_not_exists(#ttl, :ttl)",
            ExpressionAttributeNames={"#cnt": "count", "#ttl": "ttl"},
            ExpressionAttributeValues={":one": 1, ":ttl": ttl},
            ReturnValues="UPDATED_NEW",
        )
        count = int(resp["Attributes"]["count"])
    except ClientError as exc:
        logger.error("Rate limit check error: %s", exc)
        # Fail open -- do not block requests due to DynamoDB errors
        return

    if count > rpm_limit:
        _emit_metric("RateLimitExceeded", 1, dimensions=[{"Name": "ApiKey", "Value": api_key[:8]}])
        raise OverflowError(f"Rate limit exceeded: {count}/{rpm_limit} RPM.")


# ---------------------------------------------------------------------------
# Budget enforcement
# ---------------------------------------------------------------------------
def check_budget(api_key: str, key_record: dict[str, Any]) -> None:
    """
    Deny the request if used_this_month >= monthly_budget.

    Raises PermissionError (403) on budget breach.
    """
    monthly_budget = float(key_record.get("monthly_budget", 0))
    used           = float(key_record.get("used_this_month", 0))

    if monthly_budget <= 0:
        return  # no budget cap

    if used >= monthly_budget:
        _emit_metric("BudgetExceeded", 1, dimensions=[{"Name": "ApiKey", "Value": api_key[:8]}])
        raise PermissionError(
            f"Monthly budget of ${monthly_budget:.2f} exceeded (used ${used:.4f})."
        )


# ---------------------------------------------------------------------------
# Prompt cache
# ---------------------------------------------------------------------------
def _build_cache_key(model: str, messages: list[dict], params: dict) -> str:
    """SHA-256 of normalised (model + messages + params)."""
    canonical = json.dumps(
        {"model": model.lower(), "messages": messages, "params": params},
        sort_keys=True,
        ensure_ascii=False,
    )
    return hashlib.sha256(canonical.encode()).hexdigest()


def get_cached_response(prompt_hash: str) -> dict[str, Any] | None:
    """Return cached response dict or None if not found / expired."""
    if not ENABLE_CACHING:
        return None
    try:
        resp = tbl_cache.get_item(Key={"prompt_hash": prompt_hash})
        item = resp.get("Item")
        if not item:
            return None
        # Double-check TTL (DynamoDB TTL deletion is eventually consistent)
        if item.get("ttl", 0) < int(time.time()):
            return None
        _emit_metric("CacheHit", 1)
        return json.loads(item["response"])
    except ClientError as exc:
        logger.warning("Cache get error: %s", exc)
        return None


def cache_response(prompt_hash: str, response: dict[str, Any], ttl: int = CACHE_TTL) -> None:
    """Persist a response to the cache table."""
    if not ENABLE_CACHING:
        return
    try:
        tbl_cache.put_item(Item={
            "prompt_hash": prompt_hash,
            "response":    json.dumps(response),
            "ttl":         int(time.time()) + ttl,
        })
    except ClientError as exc:
        logger.warning("Cache put error: %s", exc)


# ---------------------------------------------------------------------------
# Bedrock invocation
# ---------------------------------------------------------------------------
def _build_bedrock_body(model: str, messages: list[dict], params: dict) -> tuple[str, bytes]:
    """
    Build the Bedrock request body appropriate for the model family.

    Returns (content_type, body_bytes).
    Supports:
      - Anthropic Claude (messages API)
      - Meta Llama (prompt format)
      - Amazon Titan Text
      - Cohere / Titan embeddings (for /v1/embeddings)
    """
    max_tokens   = params.get("max_tokens", 4096)
    temperature  = params.get("temperature", 0.7)
    top_p        = params.get("top_p", 0.9)

    if model.startswith("anthropic."):
        # Claude Messages API
        system_msgs = [m["content"] for m in messages if m["role"] == "system"]
        user_msgs   = [m for m in messages if m["role"] != "system"]
        body: dict[str, Any] = {
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": max_tokens,
            "messages": user_msgs,
        }
        if system_msgs:
            body["system"] = "\n\n".join(system_msgs)
        if temperature is not None:
            body["temperature"] = temperature
        if top_p is not None:
            body["top_p"] = top_p
        return "application/json", json.dumps(body).encode()

    if model.startswith("meta.llama"):
        # Build a simple chat prompt for Llama
        prompt_parts = []
        for m in messages:
            role = m["role"]
            content = m["content"]
            if role == "system":
                prompt_parts.append(f"<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n{content}<|eot_id|>")
            elif role == "user":
                prompt_parts.append(f"<|start_header_id|>user<|end_header_id|>\n{content}<|eot_id|>")
            elif role == "assistant":
                prompt_parts.append(f"<|start_header_id|>assistant<|end_header_id|>\n{content}<|eot_id|>")
        prompt_parts.append("<|start_header_id|>assistant<|end_header_id|>")
        body = {
            "prompt":       "".join(prompt_parts),
            "max_gen_len":  max_tokens,
            "temperature":  temperature,
            "top_p":        top_p,
        }
        return "application/json", json.dumps(body).encode()

    if model.startswith("amazon.titan-text"):
        combined = "\n".join(m["content"] for m in messages)
        body = {
            "inputText": combined,
            "textGenerationConfig": {
                "maxTokenCount": max_tokens,
                "temperature":   temperature,
                "topP":          top_p,
            },
        }
        return "application/json", json.dumps(body).encode()

    # Fallback: send raw prompt
    combined = "\n".join(m["content"] for m in messages)
    body = {"inputText": combined}
    return "application/json", json.dumps(body).encode()


def _build_embedding_body(model: str, input_text: str) -> tuple[str, bytes]:
    """Build the Bedrock request body for embedding models."""
    if model.startswith("amazon.titan-embed"):
        body = {"inputText": input_text}
    elif model.startswith("cohere.embed"):
        body = {"texts": [input_text], "input_type": "search_document"}
    else:
        body = {"inputText": input_text}
    return "application/json", json.dumps(body).encode()


def _parse_bedrock_response(model: str, raw: bytes) -> tuple[str, int, int]:
    """
    Parse Bedrock response bytes into (text, input_tokens, output_tokens).
    """
    data = json.loads(raw)

    if model.startswith("anthropic."):
        content    = data.get("content", [{}])
        text       = content[0].get("text", "") if content else ""
        usage      = data.get("usage", {})
        in_tok     = usage.get("input_tokens", 0)
        out_tok    = usage.get("output_tokens", 0)
        return text, in_tok, out_tok

    if model.startswith("meta.llama"):
        text    = data.get("generation", "")
        in_tok  = data.get("prompt_token_count", 0)
        out_tok = data.get("generation_token_count", 0)
        return text, in_tok, out_tok

    if model.startswith("amazon.titan-text"):
        results = data.get("results", [{}])
        text    = results[0].get("outputText", "") if results else ""
        in_tok  = data.get("inputTextTokenCount", 0)
        out_tok = results[0].get("tokenCount", 0) if results else 0
        return text, in_tok, out_tok

    # Generic fallback
    text = str(data)
    return text, 0, 0


def _invoke_model(model: str, messages: list[dict], params: dict) -> tuple[str, int, int]:
    """Invoke a single Bedrock model and return (text, in_tokens, out_tokens)."""
    content_type, body = _build_bedrock_body(model, messages, params)
    resp = bedrock.invoke_model(
        modelId=model,
        body=body,
        contentType=content_type,
        accept="application/json",
    )
    raw = resp["body"].read()
    return _parse_bedrock_response(model, raw)


def invoke_with_fallback(
    messages: list[dict],
    params: dict,
    models: list[str],
) -> tuple[str, str, int, int]:
    """
    Try each model in order. On ThrottlingException advance to the next.

    Returns (text, model_used, input_tokens, output_tokens).
    Raises RuntimeError if all models are exhausted.
    """
    last_exc: Exception | None = None

    for model in models:
        try:
            logger.info("Invoking model: %s", model)
            text, in_tok, out_tok = _invoke_model(model, messages, params)
            _emit_metric("BedrockInvocations", 1, dimensions=[{"Name": "Model", "Value": model}])
            return text, model, in_tok, out_tok
        except ClientError as exc:
            code = exc.response["Error"]["Code"]
            if code == "ThrottlingException":
                logger.warning("ThrottlingException on %s, trying fallback.", model)
                _emit_metric("BedrockThrottling", 1, dimensions=[{"Name": "Model", "Value": model}])
                last_exc = exc
                continue
            # Non-throttling errors are propagated immediately
            logger.error("Bedrock invocation error on %s: %s", model, exc)
            raise

    raise RuntimeError(
        f"All models exhausted after throttling. Last error: {last_exc}"
    ) from last_exc


# ---------------------------------------------------------------------------
# Cost accounting
# ---------------------------------------------------------------------------
def calculate_cost(model: str, input_tokens: int, output_tokens: int) -> float:
    """Return cost in USD for the given token counts and model."""
    pricing = MODEL_PRICING.get(model, _DEFAULT_PRICING)
    cost = (input_tokens * pricing["input"] + output_tokens * pricing["output"]) / 1000.0
    return round(cost, 8)


def record_usage(
    api_key: str,
    model: str,
    tokens_in: int,
    tokens_out: int,
    cost: float,
) -> None:
    """
    Write a cost log record to DynamoDB and atomically increment
    used_this_month on the API key record.
    """
    record_id  = str(uuid.uuid4())
    timestamp  = int(time.time())
    ttl        = timestamp + COST_LOG_TTL_DAYS * 86400

    # Write cost log
    try:
        tbl_cost.put_item(Item={
            "record_id":    record_id,
            "api_key":      api_key,
            "timestamp":    timestamp,
            "model":        model,
            "tokens_in":    tokens_in,
            "tokens_out":   tokens_out,
            "cost_usd":     Decimal(str(cost)),
            "ttl":          ttl,
        })
    except ClientError as exc:
        logger.error("Cost log write error: %s", exc)

    # Atomic increment on api_keys table
    try:
        tbl_keys.update_item(
            Key={"api_key": api_key},
            UpdateExpression="ADD used_this_month :cost",
            ExpressionAttributeValues={":cost": Decimal(str(cost))},
        )
    except ClientError as exc:
        logger.error("Budget accumulation error: %s", exc)

    # Emit cost metric
    _emit_metric("CostUSD", cost, unit="None", dimensions=[{"Name": "ApiKey", "Value": api_key[:8]}])
    _emit_metric("TokensIn", tokens_in, dimensions=[{"Name": "Model", "Value": model}])
    _emit_metric("TokensOut", tokens_out, dimensions=[{"Name": "Model", "Value": model}])


# ---------------------------------------------------------------------------
# Response formatting
# ---------------------------------------------------------------------------
def format_openai_response(
    text: str,
    model: str,
    input_tokens: int,
    output_tokens: int,
    request_id: str,
) -> dict[str, Any]:
    """Return an OpenAI-compatible chat completion response dict."""
    return {
        "id":      f"chatcmpl-{request_id}",
        "object":  "chat.completion",
        "created": int(time.time()),
        "model":   model,
        "choices": [
            {
                "index":         0,
                "message":       {"role": "assistant", "content": text},
                "logprobs":      None,
                "finish_reason": "stop",
            }
        ],
        "usage": {
            "prompt_tokens":     input_tokens,
            "completion_tokens": output_tokens,
            "total_tokens":      input_tokens + output_tokens,
        },
    }


def format_openai_embedding_response(
    embedding: list[float],
    model: str,
    input_tokens: int,
    request_id: str,
) -> dict[str, Any]:
    """Return an OpenAI-compatible embedding response dict."""
    return {
        "object": "list",
        "data": [
            {
                "object":    "embedding",
                "embedding": embedding,
                "index":     0,
            }
        ],
        "model": model,
        "usage": {
            "prompt_tokens": input_tokens,
            "total_tokens":  input_tokens,
        },
    }


# ---------------------------------------------------------------------------
# HTTP helper
# ---------------------------------------------------------------------------
def _json_response(status: int, body: dict | str) -> dict[str, Any]:
    if isinstance(body, str):
        body = {"error": {"message": body, "type": "gateway_error"}}
    return {
        "statusCode": status,
        "headers":    {"Content-Type": "application/json"},
        "body":       json.dumps(body),
    }


def _extract_api_key(event: dict[str, Any]) -> str:
    """Extract Bearer token from Authorization header."""
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    auth    = headers.get("authorization", "")
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()
    # Also accept x-api-key header
    return headers.get("x-api-key", "").strip()


# ---------------------------------------------------------------------------
# Path handlers
# ---------------------------------------------------------------------------
def handle_chat_completions(
    event: dict[str, Any],
    api_key: str,
    key_record: dict[str, Any],
) -> dict[str, Any]:
    """Handle POST /v1/chat/completions."""
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _json_response(400, "Request body is not valid JSON.")

    messages = body.get("messages")
    if not messages or not isinstance(messages, list):
        return _json_response(400, "Field 'messages' is required and must be a list.")

    for i, msg in enumerate(messages):
        if not isinstance(msg, dict) or "role" not in msg or "content" not in msg:
            return _json_response(400, f"messages[{i}] must have 'role' and 'content' fields.")

    params = {
        "max_tokens":  body.get("max_tokens", 4096),
        "temperature": body.get("temperature", 0.7),
        "top_p":       body.get("top_p", 0.9),
    }

    # Determine model chain: per-key overrides, then global config
    request_model   = body.get("model", PRIMARY_MODEL)
    key_fallbacks   = key_record.get("fallback_models", FALLBACK_MODELS)
    model_chain     = [request_model] + list(key_fallbacks)

    request_id   = str(uuid.uuid4()).replace("-", "")[:24]
    cache_key    = _build_cache_key(request_model, messages, params)

    # Cache lookup
    cached = get_cached_response(cache_key)
    if cached:
        logger.info("Cache hit for request %s", request_id)
        cached["id"] = f"chatcmpl-{request_id}"
        return _json_response(200, cached)

    _emit_metric("CacheMiss", 1)

    # Invoke Bedrock
    try:
        text, model_used, in_tok, out_tok = invoke_with_fallback(messages, params, model_chain)
    except RuntimeError as exc:
        logger.error("invoke_with_fallback failed: %s", exc)
        return _json_response(503, "Bedrock invocation failed. Please retry.")
    except ClientError as exc:
        logger.error("Bedrock ClientError: %s", exc)
        return _json_response(502, "Upstream Bedrock error.")

    cost     = calculate_cost(model_used, in_tok, out_tok)
    response = format_openai_response(text, model_used, in_tok, out_tok, request_id)

    # Persist cache + cost asynchronously (best-effort)
    cache_response(cache_key, response)
    record_usage(api_key, model_used, in_tok, out_tok, cost)

    _emit_metric("Requests", 1, dimensions=[{"Name": "Endpoint", "Value": "chat_completions"}])
    return _json_response(200, response)


def handle_embeddings(
    event: dict[str, Any],
    api_key: str,
    key_record: dict[str, Any],
) -> dict[str, Any]:
    """Handle POST /v1/embeddings."""
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _json_response(400, "Request body is not valid JSON.")

    input_text = body.get("input")
    if not input_text or not isinstance(input_text, str):
        return _json_response(400, "Field 'input' is required and must be a string.")

    model = body.get("model", "amazon.titan-embed-text-v2:0")

    # Check cache
    cache_key = hashlib.sha256(f"embed#{model}#{input_text}".encode()).hexdigest()
    cached    = get_cached_response(cache_key)
    request_id = str(uuid.uuid4()).replace("-", "")[:24]

    if cached:
        cached["id"] = f"embed-{request_id}"
        return _json_response(200, cached)

    # Invoke embedding model
    content_type, body_bytes = _build_embedding_body(model, input_text)
    try:
        resp = bedrock.invoke_model(
            modelId=model,
            body=body_bytes,
            contentType=content_type,
            accept="application/json",
        )
        data = json.loads(resp["body"].read())
    except ClientError as exc:
        logger.error("Embedding invocation error: %s", exc)
        return _json_response(502, "Embedding model invocation failed.")

    # Parse embedding output
    if model.startswith("amazon.titan-embed"):
        embedding = data.get("embedding", [])
        in_tok    = data.get("inputTextTokenCount", 0)
    elif model.startswith("cohere.embed"):
        embedding = data.get("embeddings", [[]])[0]
        in_tok    = 0
    else:
        embedding = data.get("embedding", [])
        in_tok    = 0

    cost     = calculate_cost(model, in_tok, 0)
    response = format_openai_embedding_response(embedding, model, in_tok, request_id)

    cache_response(cache_key, response)
    record_usage(api_key, model, in_tok, 0, cost)

    _emit_metric("Requests", 1, dimensions=[{"Name": "Endpoint", "Value": "embeddings"}])
    return _json_response(200, response)


# ---------------------------------------------------------------------------
# Lambda entry point
# ---------------------------------------------------------------------------
def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """
    Main Lambda handler for API Gateway HTTP API.

    Routes:
      POST /v1/chat/completions
      POST /v1/embeddings
    """
    logger.info("Event: %s", json.dumps({k: v for k, v in event.items() if k != "body"}))

    path   = event.get("rawPath") or event.get("path", "")
    method = (event.get("requestContext", {}).get("http", {}).get("method") or
              event.get("httpMethod", "GET")).upper()

    if method == "GET" and path in ("/health", "/v1/health"):
        return _json_response(200, {"status": "ok"})

    if method != "POST":
        return _json_response(405, f"Method {method} is not allowed.")

    # Extract and validate API key
    api_key = _extract_api_key(event)
    if not api_key:
        return _json_response(401, "Authorization header with Bearer token is required.")

    try:
        key_record = authorize_request(api_key)
    except PermissionError as exc:
        return _json_response(401, str(exc))
    except RuntimeError as exc:
        return _json_response(500, str(exc))

    # Rate limit check
    rpm_limit = int(key_record.get("rate_limit_rpm", 60))
    try:
        check_rate_limit(api_key, rpm_limit)
    except OverflowError as exc:
        return _json_response(429, str(exc))

    # Budget check
    try:
        check_budget(api_key, key_record)
    except PermissionError as exc:
        return _json_response(403, str(exc))

    # Route to path handler
    if path.rstrip("/") == "/v1/chat/completions":
        return handle_chat_completions(event, api_key, key_record)

    if path.rstrip("/") == "/v1/embeddings":
        return handle_embeddings(event, api_key, key_record)

    return _json_response(404, f"Path '{path}' not found. Supported: /v1/chat/completions, /v1/embeddings.")
