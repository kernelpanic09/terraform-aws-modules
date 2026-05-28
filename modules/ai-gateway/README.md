# ai-gateway Terraform Module

A production-grade OpenAI-compatible proxy for AWS Bedrock. Drop it into any AWS account, point your OpenAI SDK clients at the output URL, and get rate limiting, cost accounting, prompt caching, model fallback, and observability out of the box.

## Architecture

```
Client (OpenAI SDK)
        |
        | HTTPS  Bearer token
        v
API Gateway HTTP API
  POST /v1/chat/completions
  POST /v1/embeddings
  GET  /health
        |
        | Lambda REQUEST authorizer
        | (validates API key in DynamoDB api_keys table)
        v
Lambda proxy function
  1. authorize_request()    -- DynamoDB api_keys lookup
  2. check_rate_limit()     -- atomic counter in DynamoDB rate_counter (per-minute TTL)
  3. check_budget()         -- monthly_budget vs used_this_month
  4. get_cached_response()  -- SHA-256 keyed DynamoDB prompt_cache (optional)
  5. invoke_with_fallback() -- primary model -> fallback[0] -> fallback[1]
  6. calculate_cost()       -- token * per-model pricing
  7. record_usage()         -- DynamoDB cost_log + budget increment
  8. format_openai_response()
        |
        v
AWS Bedrock (Claude, Llama, Titan)
        |
CloudWatch (metrics, alarms, dashboard)
SNS (alarm emails)
WAF (optional -- rate limiting + managed rules)
KMS (DynamoDB encryption at rest)
```

## Features

- **OpenAI-compatible API** -- clients using `openai.OpenAI(base_url=..., api_key=...)` work without code changes
- **API key authentication** -- Bearer token or `X-Api-Key` header, validated by a separate authorizer Lambda
- **Per-key rate limiting** -- per-minute sliding window using DynamoDB atomic ADD + TTL; returns HTTP 429 on breach
- **Per-key monthly budget** -- denies requests when `used_this_month >= monthly_budget`; returns HTTP 403
- **Prompt caching** -- SHA-256(model + messages + params) keyed, configurable TTL, dramatically reduces cost for repeated queries
- **Model fallback chain** -- on `ThrottlingException` the proxy advances to fallback models in order
- **Cost accounting** -- per-model token pricing baked in; every invocation is recorded to DynamoDB and the monthly counter is updated atomically
- **CloudWatch dashboard** -- total requests, cache hit/miss, daily cost, per-model usage, Lambda duration percentiles, throttling events
- **CloudWatch alarms** -- high error rate, Bedrock throttling, Lambda errors, Lambda P99 duration, rate limit abuse
- **WAF v2 (optional)** -- per-IP rate limiting + AWS Managed Rules (CRS + known bad inputs)
- **KMS encryption** -- all DynamoDB tables encrypted with a customer-managed KMS key with automatic rotation
- **X-Ray tracing** -- active tracing on the proxy Lambda

## Supported Models

| Model ID | Family | Notes |
|---|---|---|
| `anthropic.claude-haiku-4-5-20251001-v1:0` | Claude | Default primary model |
| `anthropic.claude-3-5-haiku-20241022-v1:0` | Claude | |
| `anthropic.claude-3-haiku-20240307-v1:0` | Claude | Good fallback |
| `anthropic.claude-3-sonnet-20240229-v1:0` | Claude | |
| `anthropic.claude-3-5-sonnet-20241022-v2:0` | Claude | |
| `anthropic.claude-3-opus-20240229-v1:0` | Claude | Highest quality |
| `meta.llama3-8b-instruct-v1:0` | Llama | Good low-cost fallback |
| `meta.llama3-70b-instruct-v1:0` | Llama | |
| `meta.llama3-1-8b-instruct-v1:0` | Llama | |
| `meta.llama3-1-70b-instruct-v1:0` | Llama | |
| `amazon.titan-text-express-v1` | Titan | |
| `amazon.titan-text-lite-v1` | Titan | |
| `amazon.titan-embed-text-v2:0` | Titan Embeddings | Default for /v1/embeddings |
| `cohere.embed-english-v3` | Cohere | |

Models not in the pricing table fall back to a $0.001/$0.005 per 1K token default.

## DynamoDB Tables

| Table | PK | Purpose | TTL |
|---|---|---|---|
| `{name}-api-keys` | `api_key` | Key metadata, budget counters | None |
| `{name}-rate-counter` | `counter_key` | Per-key per-minute request counter | 90 seconds |
| `{name}-cost-log` | `record_id` | Per-request cost records | Configurable |
| `{name}-prompt-cache` | `prompt_hash` | Cached responses | Configurable |

### API Key Record Schema

```json
{
  "api_key":          "prod-<random>",
  "enabled":          true,
  "monthly_budget":   500.0,
  "used_this_month":  12.34,
  "rate_limit_rpm":   100,
  "fallback_models":  "[\"anthropic.claude-3-haiku-20240307-v1:0\"]",
  "description":      "Production workloads"
}
```

- Set `monthly_budget` to `0` to disable budget enforcement for a key.
- Set `rate_limit_rpm` to `0` to disable rate limiting for a key.
- Set `fallback_models` to a JSON array string to override the module-level `fallback_models` variable per key.

### Resetting the Monthly Budget Counter

Run this at the start of each month (or wire it to an EventBridge scheduled rule):

```bash
aws dynamodb scan \
  --table-name "${name}-api-keys" \
  --projection-expression "api_key" \
  --output json | jq -r '.Items[].api_key.S' | while read key; do
    aws dynamodb update-item \
      --table-name "${name}-api-keys" \
      --key "{\"api_key\":{\"S\":\"$key\"}}" \
      --update-expression "SET used_this_month = :zero" \
      --expression-attribute-values '{":zero":{"N":"0"}}'
done
```

## Usage

### Minimal

```hcl
module "ai_gateway" {
  source = "path/to/module"
  name   = "my-ai-gw"
}
```

### Production with WAF and alarms

```hcl
module "ai_gateway" {
  source = "path/to/module"

  name = "acme-ai-gw"

  primary_model = "anthropic.claude-haiku-4-5-20251001-v1:0"
  fallback_models = [
    "anthropic.claude-3-haiku-20240307-v1:0",
    "meta.llama3-8b-instruct-v1:0",
  ]

  enable_caching    = true
  cache_ttl_seconds = 3600

  enable_waf     = true
  waf_rate_limit = 3000

  alarm_emails = ["ops@example.com"]

  lambda_memory_mb       = 512
  lambda_timeout_seconds = 60
  log_retention_days     = 30

  tags = {
    Team = "platform"
  }
}
```

### Client integration (OpenAI SDK)

```python
from openai import OpenAI

client = OpenAI(
    api_key="your-api-key",
    base_url="https://<api-id>.execute-api.us-east-1.amazonaws.com/v1",
)

# Chat completion
response = client.chat.completions.create(
    model="anthropic.claude-haiku-4-5-20251001-v1:0",
    messages=[
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user", "content": "Explain transformer attention in one paragraph."},
    ],
    max_tokens=512,
    temperature=0.7,
)
print(response.choices[0].message.content)

# Embeddings
emb = client.embeddings.create(
    model="amazon.titan-embed-text-v2:0",
    input="The quick brown fox",
)
print(emb.data[0].embedding[:5])
```

### cURL

```bash
ENDPOINT="https://<api-id>.execute-api.us-east-1.amazonaws.com"
KEY="your-api-key"

# Chat
curl -s -X POST "$ENDPOINT/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "anthropic.claude-haiku-4-5-20251001-v1:0",
    "messages": [{"role": "user", "content": "Hello!"}]
  }' | jq .

# Embeddings
curl -s -X POST "$ENDPOINT/v1/embeddings" \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "amazon.titan-embed-text-v2:0",
    "input": "The quick brown fox"
  }' | jq .choices

# Health check (no auth required)
curl -s "$ENDPOINT/health"
```

## Variables

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | `string` | required | Prefix for all resources. 3-30 chars, lowercase alphanumeric + hyphens. |
| `primary_model` | `string` | `anthropic.claude-haiku-4-5-20251001-v1:0` | Default Bedrock model. |
| `fallback_models` | `list(string)` | `["anthropic.claude-3-haiku-20240307-v1:0", "meta.llama3-8b-instruct-v1:0"]` | Fallback chain on throttling. Max 3. |
| `enable_caching` | `bool` | `true` | Enable prompt response cache. |
| `cache_ttl_seconds` | `number` | `3600` | Cache TTL (60-86400). |
| `enable_waf` | `bool` | `false` | Attach WAF with rate limiting and managed rules. |
| `waf_rate_limit` | `number` | `2000` | WAF per-IP requests per 5 minutes. |
| `alarm_emails` | `list(string)` | `[]` | Email addresses for CloudWatch alarm notifications. |
| `log_retention_days` | `number` | `30` | Lambda CloudWatch log retention. |
| `kms_deletion_window` | `number` | `14` | KMS key deletion window (7-30 days). |
| `lambda_memory_mb` | `number` | `512` | Proxy Lambda memory (128-10240 MB). |
| `lambda_timeout_seconds` | `number` | `60` | Proxy Lambda timeout (10-900 seconds). |
| `cost_log_retention_days` | `number` | `90` | DynamoDB cost log record TTL (1-365 days). |
| `budget_alarm_threshold_pct` | `number` | `80` | Budget alarm at this percentage of monthly_budget. |
| `error_rate_alarm_threshold_pct` | `number` | `5` | Error rate percentage to trigger alarm. |
| `throttle_alarm_threshold` | `number` | `10` | Bedrock throttling events per 5 min to trigger alarm. |
| `tags` | `map(string)` | `{}` | Tags applied to all resources. |

## Outputs

| Name | Description |
|---|---|
| `api_endpoint` | Base URL of the gateway (use as `base_url`). |
| `chat_completions_endpoint` | Full URL for `/v1/chat/completions`. |
| `embeddings_endpoint` | Full URL for `/v1/embeddings`. |
| `api_id` | API Gateway HTTP API ID. |
| `proxy_lambda_name` | Name of the proxy Lambda function. |
| `api_keys_table_name` | DynamoDB table for API key management. |
| `cost_log_table_name` | DynamoDB cost log table. |
| `prompt_cache_table_name` | DynamoDB prompt cache table. |
| `kms_key_arn` | KMS key ARN for DynamoDB encryption. |
| `sns_alarm_topic_arn` | SNS topic for alarms. |
| `dashboard_url` | Direct link to the CloudWatch dashboard. |
| `waf_web_acl_arn` | WAF WebACL ARN (empty string if WAF is disabled). |

## IAM Permissions Required

The AWS principal running `terraform apply` needs:

```
apigateway:*
dynamodb:CreateTable, DeleteTable, DescribeTable, UpdateTable, PutItem, ...
iam:CreateRole, AttachRolePolicy, PutRolePolicy, PassRole
kms:CreateKey, CreateAlias, DescribeKey, PutKeyPolicy, EnableKeyRotation
lambda:CreateFunction, UpdateFunctionCode, AddPermission, ...
logs:CreateLogGroup, PutRetentionPolicy
sns:CreateTopic, Subscribe
cloudwatch:PutMetricAlarm, PutDashboard
wafv2:CreateWebACL, AssociateWebACL   (only if enable_waf = true)
```

For least-privilege, scope `bedrock:InvokeModel` to the specific model ARNs in your model chain.

## Operational Runbook

### Adding a new API key

```bash
aws dynamodb put-item \
  --table-name "${name}-api-keys" \
  --item '{
    "api_key":          {"S": "prod-<32-char-random>"},
    "enabled":          {"BOOL": true},
    "monthly_budget":   {"N": "500"},
    "used_this_month":  {"N": "0"},
    "rate_limit_rpm":   {"N": "100"},
    "description":      {"S": "Production key"}
  }'
```

### Disabling a key (emergency revocation)

```bash
aws dynamodb update-item \
  --table-name "${name}-api-keys" \
  --key '{"api_key": {"S": "prod-<key>"}}' \
  --update-expression "SET enabled = :false" \
  --expression-attribute-values '{":false": {"BOOL": false}}'
```

### Viewing recent cost records

```bash
aws dynamodb query \
  --table-name "${name}-cost-log" \
  --index-name api-key-time-index \
  --key-condition-expression "api_key = :k AND #ts > :since" \
  --expression-attribute-names '{"#ts": "timestamp"}' \
  --expression-attribute-values '{
    ":k":    {"S": "prod-<key>"},
    ":since": {"N": "'$(date -d '24 hours ago' +%s)'"}
  }'
```

### Checking cache occupancy

```bash
aws dynamodb scan \
  --table-name "${name}-prompt-cache" \
  --select COUNT
```

## Security Considerations

- API keys are stored in DynamoDB, not in environment variables or SSM -- keys are only in transit during the API call.
- The authorizer Lambda result TTL is set to 0 to prevent stale allow decisions from a recently revoked key being cached by API Gateway.
- All DynamoDB tables use customer-managed KMS keys with automatic rotation.
- CloudWatch log groups are also encrypted with the same KMS key.
- WAF managed rules protect against common web exploits and known bad inputs.
- The Lambda execution role follows least-privilege: `bedrock:InvokeModel` is scoped to the specific model ARNs in the fallback chain.
- Budget enforcement happens inside the proxy Lambda AFTER the authorizer -- a revoked key cannot bypass the budget check.

## Cost Estimation

For 1 million requests per month to Claude Haiku 4 (avg 500 input + 200 output tokens):

| Component | Estimated Cost |
|---|---|
| API Gateway HTTP API | ~$1.00 |
| Lambda invocations (2x per request -- authorizer + proxy) | ~$4.00 |
| DynamoDB (PAY_PER_REQUEST) | ~$5.00 |
| CloudWatch Logs | ~$2.00 |
| Bedrock Claude Haiku (500 in + 200 out tokens * 1M) | ~$1,200 |
| WAF (optional) | ~$10.00 |

The gateway overhead is negligible compared to Bedrock costs.

## Requirements

| Name | Version |
|---|---|
| terraform | >= 1.5.0 |
| aws | >= 5.30.0 |
| archive | >= 2.4.0 |
| local | >= 2.4.0 |
| random | >= 3.5.0 |
