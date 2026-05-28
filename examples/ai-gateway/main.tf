################################################################################
# Example: Deploy the ai-gateway module with three API keys
#
# This example creates:
#  - A gateway named "acme-ai-gateway" in us-east-1
#  - WAF enabled with AWS managed rules
#  - Alarm emails wired to an ops alias
#  - Three API keys seeded into DynamoDB:
#      production      -- $500/month budget, 100 RPM
#      staging         -- $50/month budget,  30 RPM
#      internal-tools  -- $20/month budget,  10 RPM
#
# Usage:
#   terraform init
#   terraform apply
#
# After apply, retrieve the endpoint from outputs and add API keys to DynamoDB:
#   aws dynamodb put-item --table-name <api_keys_table_name> \
#     --item '{"api_key":{"S":"prod-<your-secret>"},"enabled":{"BOOL":true},"monthly_budget":{"N":"500"},"used_this_month":{"N":"0"},"rate_limit_rpm":{"N":"100"}}'
################################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.30.0"
    }
  }

  # Recommended: use remote state for production
  # backend "s3" {
  #   bucket         = "my-terraform-state"
  #   key            = "ai-gateway/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   dynamodb_table = "terraform-state-lock"
  # }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = "ai-gateway"
      Environment = "production"
      Owner       = "platform-team"
    }
  }
}

# ============================================================
# Gateway module
# ============================================================
module "ai_gateway" {
  source = "../module"

  name = "acme-ai-gw"

  # Model configuration
  primary_model = "anthropic.claude-haiku-4-5-20251001-v1:0"
  fallback_models = [
    "anthropic.claude-3-haiku-20240307-v1:0",
    "meta.llama3-8b-instruct-v1:0",
  ]

  # Caching
  enable_caching    = true
  cache_ttl_seconds = 3600

  # WAF protection
  enable_waf     = true
  waf_rate_limit = 3000

  # Alerting
  alarm_emails = [
    "ops@acme.example.com",
    "platform-alerts@acme.example.com",
  ]

  # Alarm thresholds
  budget_alarm_threshold_pct     = 80
  error_rate_alarm_threshold_pct = 5
  throttle_alarm_threshold       = 20

  # Lambda sizing
  lambda_memory_mb       = 512
  lambda_timeout_seconds = 60

  # Retention
  log_retention_days      = 30
  cost_log_retention_days = 90
  kms_deletion_window     = 14

  tags = {
    Team        = "platform"
    CostCenter  = "engineering"
  }
}

# ============================================================
# Seed API keys into DynamoDB
# (In production, manage keys via a secrets pipeline, not Terraform state)
# ============================================================

locals {
  api_keys = {
    production = {
      api_key         = "prod-${random_password.keys["production"].result}"
      enabled         = true
      monthly_budget  = 500
      rate_limit_rpm  = 100
      description     = "Production workloads"
      fallback_models = jsonencode(["anthropic.claude-3-haiku-20240307-v1:0"])
    }
    staging = {
      api_key         = "stg-${random_password.keys["staging"].result}"
      enabled         = true
      monthly_budget  = 50
      rate_limit_rpm  = 30
      description     = "Staging and QA environments"
      fallback_models = jsonencode([])
    }
    internal-tools = {
      api_key         = "int-${random_password.keys["internal-tools"].result}"
      enabled         = true
      monthly_budget  = 20
      rate_limit_rpm  = 10
      description     = "Internal developer tooling"
      fallback_models = jsonencode([])
    }
  }
}

resource "random_password" "keys" {
  for_each = local.api_keys
  length   = 32
  special  = false
}

resource "aws_dynamodb_table_item" "api_keys" {
  for_each   = local.api_keys
  table_name = module.ai_gateway.api_keys_table_name
  hash_key   = "api_key"

  item = jsonencode({
    api_key         = { S = each.value.api_key }
    enabled         = { BOOL = each.value.enabled }
    monthly_budget  = { N = tostring(each.value.monthly_budget) }
    used_this_month = { N = "0" }
    rate_limit_rpm  = { N = tostring(each.value.rate_limit_rpm) }
    description     = { S = each.value.description }
    fallback_models = { S = each.value.fallback_models }
    created_at      = { N = tostring(time_static.now.unix) }
  })
}

resource "time_static" "now" {}

# ============================================================
# Outputs
# ============================================================
output "gateway_endpoint" {
  description = "Base URL for the AI Gateway. Set this as base_url in your OpenAI client."
  value       = module.ai_gateway.api_endpoint
}

output "chat_completions_url" {
  description = "Full URL for chat completions endpoint."
  value       = module.ai_gateway.chat_completions_endpoint
}

output "embeddings_url" {
  description = "Full URL for embeddings endpoint."
  value       = module.ai_gateway.embeddings_endpoint
}

output "api_keys_table" {
  description = "DynamoDB table name for API key management."
  value       = module.ai_gateway.api_keys_table_name
}

output "cost_log_table" {
  description = "DynamoDB table name for cost log queries."
  value       = module.ai_gateway.cost_log_table_name
}

output "dashboard_url" {
  description = "CloudWatch dashboard URL."
  value       = module.ai_gateway.dashboard_url
}

output "sns_alarm_topic" {
  description = "SNS topic ARN for alarm subscriptions."
  value       = module.ai_gateway.sns_alarm_topic_arn
}

# SENSITIVE: printed only via 'terraform output -json api_key_values'
output "api_key_values" {
  description = "Generated API key values. Store securely in a secrets manager."
  sensitive   = true
  value = {
    for name, cfg in local.api_keys : name => cfg.api_key
  }
}

# ============================================================
# Quick-start usage guide (post-apply)
# ============================================================
output "usage_example" {
  description = "Python snippet showing how to call the gateway using the OpenAI SDK."
  value       = <<-EOF
    # Install: pip install openai
    # Retrieve key: terraform output -json api_key_values | jq '.production'

    from openai import OpenAI

    client = OpenAI(
        api_key="<production-api-key>",
        base_url="${module.ai_gateway.api_endpoint}/v1",
    )

    response = client.chat.completions.create(
        model="anthropic.claude-haiku-4-5-20251001-v1:0",
        messages=[{"role": "user", "content": "Hello, world!"}],
    )
    print(response.choices[0].message.content)
  EOF
}
