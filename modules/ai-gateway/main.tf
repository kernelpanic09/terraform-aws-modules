# ============================================================
# ai-gateway module. main.tf
# ============================================================

locals {
  prefix = var.name

  common_tags = merge(var.tags, {
    Module    = "ai-gateway"
    ManagedBy = "Terraform"
  })

  model_chain   = concat([var.primary_model], var.fallback_models)
  fallback_json = jsonencode(var.fallback_models)

  # Lambda source: zip the handler.py file
  lambda_src_dir = "${path.module}/lambda"
}

# ============================================================
# KMS key for DynamoDB encryption at rest
# ============================================================
resource "aws_kms_key" "main" {
  description             = "${local.prefix} AI Gateway DynamoDB encryption key"
  deletion_window_in_days = var.kms_deletion_window
  enable_key_rotation     = true
  tags                    = local.common_tags
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.prefix}-ai-gateway"
  target_key_id = aws_kms_key.main.key_id
}

# ============================================================
# DynamoDB tables
# ============================================================

# API Keys table. stores key metadata and budget counters
resource "aws_dynamodb_table" "api_keys" {
  name         = "${local.prefix}-api-keys"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "api_key"

  attribute {
    name = "api_key"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.main.arn
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = local.common_tags
}

# Rate counter table. per-key per-minute atomic counter
resource "aws_dynamodb_table" "rate_counter" {
  name         = "${local.prefix}-rate-counter"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "counter_key"

  attribute {
    name = "counter_key"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.main.arn
  }

  tags = local.common_tags
}

# Cost log table. per-request cost records
resource "aws_dynamodb_table" "cost_log" {
  name         = "${local.prefix}-cost-log"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "record_id"

  attribute {
    name = "record_id"
    type = "S"
  }

  # GSI for querying by api_key + timestamp
  attribute {
    name = "api_key"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "N"
  }

  global_secondary_index {
    name            = "api-key-time-index"
    hash_key        = "api_key"
    range_key       = "timestamp"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.main.arn
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = local.common_tags
}

# Prompt cache table. SHA-256 keyed response cache
resource "aws_dynamodb_table" "prompt_cache" {
  name         = "${local.prefix}-prompt-cache"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "prompt_hash"

  attribute {
    name = "prompt_hash"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.main.arn
  }

  tags = local.common_tags
}

# ============================================================
# IAM role for proxy Lambda
# ============================================================
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "proxy_lambda" {
  name               = "${local.prefix}-proxy-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "proxy_lambda" {
  # CloudWatch Logs
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }

  # DynamoDB access on all four tables
  statement {
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:Query",
    ]
    resources = [
      aws_dynamodb_table.api_keys.arn,
      aws_dynamodb_table.rate_counter.arn,
      aws_dynamodb_table.cost_log.arn,
      aws_dynamodb_table.prompt_cache.arn,
      "${aws_dynamodb_table.cost_log.arn}/index/*",
    ]
  }

  # Bedrock model invocation. all models in the chain
  statement {
    effect  = "Allow"
    actions = ["bedrock:InvokeModel"]
    resources = [
      for model in local.model_chain :
      "arn:aws:bedrock:*::foundation-model/${model}"
    ]
  }

  # KMS decrypt for DynamoDB SSE
  statement {
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.main.arn]
  }

  # CloudWatch metrics
  statement {
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }

  # X-Ray tracing
  statement {
    effect = "Allow"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "proxy_lambda" {
  name   = "${local.prefix}-proxy-lambda-policy"
  role   = aws_iam_role.proxy_lambda.id
  policy = data.aws_iam_policy_document.proxy_lambda.json
}

# ============================================================
# IAM role for authorizer Lambda
# ============================================================
resource "aws_iam_role" "authorizer_lambda" {
  name               = "${local.prefix}-authorizer-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "authorizer_lambda" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["dynamodb:GetItem"]
    resources = [aws_dynamodb_table.api_keys.arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.main.arn]
  }
}

resource "aws_iam_role_policy" "authorizer_lambda" {
  name   = "${local.prefix}-authorizer-lambda-policy"
  role   = aws_iam_role.authorizer_lambda.id
  policy = data.aws_iam_policy_document.authorizer_lambda.json
}

# ============================================================
# Lambda deployment package (zip)
# ============================================================
data "archive_file" "proxy" {
  type        = "zip"
  source_dir  = local.lambda_src_dir
  output_path = "${path.module}/.build/proxy.zip"
}

# ============================================================
# Proxy Lambda function
# ============================================================
resource "aws_cloudwatch_log_group" "proxy" {
  name              = "/aws/lambda/${local.prefix}-proxy"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
  tags              = local.common_tags
}

resource "aws_lambda_function" "proxy" {
  function_name    = "${local.prefix}-proxy"
  role             = aws_iam_role.proxy_lambda.arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.proxy.output_path
  source_code_hash = data.archive_file.proxy.output_base64sha256
  memory_size      = var.lambda_memory_mb
  timeout          = var.lambda_timeout_seconds

  environment {
    variables = {
      TABLE_API_KEYS    = aws_dynamodb_table.api_keys.name
      TABLE_RATE        = aws_dynamodb_table.rate_counter.name
      TABLE_COST_LOG    = aws_dynamodb_table.cost_log.name
      TABLE_CACHE       = aws_dynamodb_table.prompt_cache.name
      PRIMARY_MODEL     = var.primary_model
      FALLBACK_MODELS   = local.fallback_json
      ENABLE_CACHING    = tostring(var.enable_caching)
      CACHE_TTL_SECONDS = tostring(var.cache_ttl_seconds)
      COST_LOG_TTL_DAYS = tostring(var.cost_log_retention_days)
      METRIC_NAMESPACE  = "${local.prefix}/AIGateway"
    }
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [
    aws_cloudwatch_log_group.proxy,
    aws_iam_role_policy.proxy_lambda,
  ]

  tags = local.common_tags
}

# ============================================================
# Authorizer Lambda function (separate small function)
# ============================================================
resource "aws_cloudwatch_log_group" "authorizer" {
  name              = "/aws/lambda/${local.prefix}-authorizer"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
  tags              = local.common_tags
}

# Inline authorizer: validates key and returns IAM policy
# Packaged from the same source dir. handler_authorizer.py
locals {
  authorizer_src = "${path.module}/lambda/authorizer"
}

resource "local_file" "authorizer_handler" {
  filename = "${path.module}/.build/authorizer/authorizer.py"
  content  = <<-PYTHON
import json
import os
import boto3
from botocore.config import Config

_RETRY = Config(retries={"max_attempts": 2, "mode": "standard"})
dynamodb = boto3.resource("dynamodb", config=_RETRY)
TABLE_API_KEYS = os.environ["TABLE_API_KEYS"]

def lambda_handler(event, context):
    """
    API Gateway Lambda authorizer (REQUEST type).
    Validates the Bearer token and returns an IAM allow/deny policy.
    """
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    auth    = headers.get("authorization", "")
    api_key = auth[7:].strip() if auth.lower().startswith("bearer ") else headers.get("x-api-key", "").strip()

    effect = "Deny"
    if api_key and len(api_key) >= 8:
        try:
            tbl  = dynamodb.Table(TABLE_API_KEYS)
            resp = tbl.get_item(Key={"api_key": api_key})
            item = resp.get("Item")
            if item and item.get("enabled", True):
                effect = "Allow"
        except Exception:
            pass

    method_arn = event.get("methodArn", "*")
    return {
        "principalId": api_key or "unknown",
        "policyDocument": {
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Action":   "execute-api:Invoke",
                    "Effect":   effect,
                    "Resource": method_arn,
                }
            ],
        },
        "context": {"api_key": api_key},
    }
PYTHON
}

data "archive_file" "authorizer" {
  type        = "zip"
  source_dir  = "${path.module}/.build/authorizer"
  output_path = "${path.module}/.build/authorizer.zip"
  depends_on  = [local_file.authorizer_handler]
}

resource "aws_lambda_function" "authorizer" {
  function_name    = "${local.prefix}-authorizer"
  role             = aws_iam_role.authorizer_lambda.arn
  runtime          = "python3.12"
  handler          = "authorizer.lambda_handler"
  filename         = data.archive_file.authorizer.output_path
  source_code_hash = data.archive_file.authorizer.output_base64sha256
  memory_size      = 128
  timeout          = 10

  environment {
    variables = {
      TABLE_API_KEYS = aws_dynamodb_table.api_keys.name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.authorizer,
    aws_iam_role_policy.authorizer_lambda,
  ]

  tags = local.common_tags
}

# ============================================================
# API Gateway HTTP API
# ============================================================
resource "aws_apigatewayv2_api" "main" {
  name          = "${local.prefix}-ai-gateway"
  protocol_type = "HTTP"
  description   = "OpenAI-compatible AI Gateway backed by AWS Bedrock"

  cors_configuration {
    allow_headers = ["Authorization", "Content-Type", "X-Api-Key"]
    allow_methods = ["POST", "GET", "OPTIONS"]
    allow_origins = ["*"]
    max_age       = 300
  }

  tags = local.common_tags
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.apigw.arn
    format          = "$context.requestId $context.status $context.error.message"
  }

  default_route_settings {
    throttling_burst_limit = 500
    throttling_rate_limit  = 1000
    logging_level          = "INFO"
    data_trace_enabled     = false
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "apigw" {
  name              = "/aws/apigateway/${local.prefix}-ai-gateway"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
  tags              = local.common_tags
}

# Lambda integration
resource "aws_apigatewayv2_integration" "proxy" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.proxy.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = (var.lambda_timeout_seconds - 5) * 1000
}

# Routes
resource "aws_apigatewayv2_route" "chat_completions" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "POST /v1/chat/completions"
  target             = "integrations/${aws_apigatewayv2_integration.proxy.id}"
  authorization_type = "CUSTOM"
  authorizer_id      = aws_apigatewayv2_authorizer.main.id
}

resource "aws_apigatewayv2_route" "embeddings" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "POST /v1/embeddings"
  target             = "integrations/${aws_apigatewayv2_integration.proxy.id}"
  authorization_type = "CUSTOM"
  authorizer_id      = aws_apigatewayv2_authorizer.main.id
}

resource "aws_apigatewayv2_route" "health" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /health"
  target    = "integrations/${aws_apigatewayv2_integration.proxy.id}"
}

# Custom authorizer
resource "aws_apigatewayv2_authorizer" "main" {
  api_id                           = aws_apigatewayv2_api.main.id
  authorizer_type                  = "REQUEST"
  authorizer_uri                   = aws_lambda_function.authorizer.invoke_arn
  identity_sources                 = ["$request.header.Authorization", "$request.header.X-Api-Key"]
  name                             = "${local.prefix}-authorizer"
  authorizer_result_ttl_in_seconds = 0 # no caching of auth results. enforce fresh checks
  enable_simple_responses          = false
}

# Lambda permissions for API Gateway
resource "aws_lambda_permission" "apigw_proxy" {
  statement_id  = "AllowAPIGatewayInvokeProxy"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.proxy.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_authorizer" {
  statement_id  = "AllowAPIGatewayInvokeAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/authorizers/${aws_apigatewayv2_authorizer.main.id}"
}

# ============================================================
# WAF v2 (optional)
# ============================================================
resource "aws_wafv2_web_acl" "main" {
  count = var.enable_waf ? 1 : 0
  name  = "${local.prefix}-ai-gateway-waf"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  # Per-IP rate limiting rule
  rule {
    name     = "RateLimit"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.prefix}-waf-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # AWS Managed Rules. Core rule set
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.prefix}-waf-common-rules"
      sampled_requests_enabled   = true
    }
  }

  # AWS Managed Rules. Known bad inputs
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.prefix}-waf-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.prefix}-waf"
    sampled_requests_enabled   = true
  }

  tags = local.common_tags
}

resource "aws_wafv2_web_acl_association" "main" {
  count        = var.enable_waf ? 1 : 0
  resource_arn = aws_apigatewayv2_stage.default.arn
  web_acl_arn  = aws_wafv2_web_acl.main[0].arn
}

# ============================================================
# SNS topic for alarms
# ============================================================
resource "aws_sns_topic" "alarms" {
  name              = "${local.prefix}-ai-gateway-alarms"
  kms_master_key_id = aws_kms_key.main.arn
  tags              = local.common_tags
}

resource "aws_sns_topic_subscription" "email" {
  count     = length(var.alarm_emails)
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_emails[count.index]
}

# ============================================================
# CloudWatch alarms
# ============================================================

# High error rate alarm
resource "aws_cloudwatch_metric_alarm" "high_error_rate" {
  alarm_name          = "${local.prefix}-high-error-rate"
  alarm_description   = "AI Gateway error rate exceeds ${var.error_rate_alarm_threshold_pct}%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = var.error_rate_alarm_threshold_pct

  metric_query {
    id          = "error_rate"
    expression  = "errors/requests*100"
    label       = "Error Rate (%)"
    return_data = true
  }

  metric_query {
    id = "errors"
    metric {
      metric_name = "5XXError"
      namespace   = "AWS/ApiGateway"
      period      = 300
      stat        = "Sum"
      dimensions = {
        ApiId = aws_apigatewayv2_api.main.id
      }
    }
  }

  metric_query {
    id = "requests"
    metric {
      metric_name = "Count"
      namespace   = "AWS/ApiGateway"
      period      = 300
      stat        = "Sum"
      dimensions = {
        ApiId = aws_apigatewayv2_api.main.id
      }
    }
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
  tags          = local.common_tags
}

# Bedrock throttling alarm
resource "aws_cloudwatch_metric_alarm" "bedrock_throttling" {
  alarm_name          = "${local.prefix}-bedrock-throttling"
  alarm_description   = "Bedrock throttling events exceed ${var.throttle_alarm_threshold} in 5 minutes"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  threshold           = var.throttle_alarm_threshold
  period              = 300
  statistic           = "Sum"
  namespace           = "${local.prefix}/AIGateway"
  metric_name         = "BedrockThrottling"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
  tags          = local.common_tags
}

# Lambda error alarm
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.prefix}-lambda-errors"
  alarm_description   = "Proxy Lambda function errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = 5
  period              = 300
  statistic           = "Sum"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.proxy.function_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
  tags          = local.common_tags
}

# Lambda duration P99 alarm
resource "aws_cloudwatch_metric_alarm" "lambda_duration" {
  alarm_name          = "${local.prefix}-lambda-p99-duration"
  alarm_description   = "Proxy Lambda P99 duration is within 20%% of the timeout"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = var.lambda_timeout_seconds * 1000 * 0.8
  period              = 300
  extended_statistic  = "p99"
  namespace           = "AWS/Lambda"
  metric_name         = "Duration"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.proxy.function_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  tags          = local.common_tags
}

# Rate limit exceeded alarm
resource "aws_cloudwatch_metric_alarm" "rate_limit_exceeded" {
  alarm_name          = "${local.prefix}-rate-limit-exceeded"
  alarm_description   = "Multiple rate limit violations. possible abuse or misconfigured client"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 50
  period              = 300
  statistic           = "Sum"
  namespace           = "${local.prefix}/AIGateway"
  metric_name         = "RateLimitExceeded"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
  tags          = local.common_tags
}

# ============================================================
# CloudWatch dashboard
# ============================================================
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.prefix}-ai-gateway"

  dashboard_body = jsonencode({
    widgets = [
      # Row 1. Traffic overview
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 8
        height = 6
        properties = {
          title  = "Total Requests"
          region = data.aws_region.current.name
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiId", aws_apigatewayv2_api.main.id, { stat = "Sum", period = 300 }]
          ]
          view = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 0
        width  = 8
        height = 6
        properties = {
          title  = "Error Rate"
          region = data.aws_region.current.name
          metrics = [
            ["AWS/ApiGateway", "5XXError", "ApiId", aws_apigatewayv2_api.main.id, { stat = "Sum", period = 300, color = "#d62728" }],
            ["AWS/ApiGateway", "4XXError", "ApiId", aws_apigatewayv2_api.main.id, { stat = "Sum", period = 300, color = "#ff7f0e" }],
          ]
          view = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 0
        width  = 8
        height = 6
        properties = {
          title  = "Cache Hit Rate"
          region = data.aws_region.current.name
          metrics = [
            ["${local.prefix}/AIGateway", "CacheHit", { stat = "Sum", period = 300, color = "#2ca02c" }],
            ["${local.prefix}/AIGateway", "CacheMiss", { stat = "Sum", period = 300, color = "#ff7f0e" }],
          ]
          view = "timeSeries"
        }
      },
      # Row 2. Cost and model usage
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Daily Cost (USD)"
          region = data.aws_region.current.name
          metrics = [
            ["${local.prefix}/AIGateway", "CostUSD", { stat = "Sum", period = 86400, color = "#9467bd" }]
          ]
          view = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Bedrock Invocations by Model"
          region = data.aws_region.current.name
          metrics = [for model in local.model_chain :
            ["${local.prefix}/AIGateway", "BedrockInvocations", "Model", model, { stat = "Sum", period = 300 }]
          ]
          view = "timeSeries"
        }
      },
      # Row 3. Lambda performance
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 8
        height = 6
        properties = {
          title  = "Lambda Duration"
          region = data.aws_region.current.name
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.proxy.function_name, { stat = "p50", period = 300, label = "p50" }],
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.proxy.function_name, { stat = "p95", period = 300, label = "p95" }],
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.proxy.function_name, { stat = "p99", period = 300, label = "p99" }],
          ]
          view = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 12
        width  = 8
        height = 6
        properties = {
          title  = "Bedrock Throttling"
          region = data.aws_region.current.name
          metrics = [
            ["${local.prefix}/AIGateway", "BedrockThrottling", { stat = "Sum", period = 300, color = "#d62728" }]
          ]
          view = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 12
        width  = 8
        height = 6
        properties = {
          title  = "Token Usage"
          region = data.aws_region.current.name
          metrics = [
            ["${local.prefix}/AIGateway", "TokensIn", { stat = "Sum", period = 300, label = "Input tokens" }],
            ["${local.prefix}/AIGateway", "TokensOut", { stat = "Sum", period = 300, label = "Output tokens" }],
          ]
          view = "timeSeries"
        }
      },
    ]
  })
}

# ============================================================
# Data sources
# ============================================================
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
