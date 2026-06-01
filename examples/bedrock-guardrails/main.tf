###############################################################################
# Example: Production customer-facing chatbot guardrail
#
# This example demonstrates a fully configured production guardrail suitable
# for a customer-facing AI assistant. It enforces:
#
#   - HIGH content safety on all harmful categories
#   - Strict PII protection (BLOCK for credentials and financial identifiers;
#     ANONYMIZE for personally identifiable contact information)
#   - Denial of investment advice and legal advice topics
#   - Internal employee ID obfuscation via custom regex
#   - Custom word blocklist for internal terminology that must not surface
#   - Contextual grounding for RAG accuracy enforcement
#   - Immutable version snapshot for stable production references
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.50.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

###############################################################################
# Application IAM role (pre-existing in a real deployment)
# Included here so the policy attachment can be demonstrated end-to-end.
###############################################################################

data "aws_iam_policy_document" "app_assume" {
  statement {
    sid     = "AllowEC2Assume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "chatbot-app-role"
  assume_role_policy = data.aws_iam_policy_document.app_assume.json

  tags = local.common_tags
}

###############################################################################
# Locals
###############################################################################

locals {
  common_tags = {
    Environment = "production"
    Team        = "platform"
    ManagedBy   = "terraform"
    Service     = "customer-chatbot"
  }
}

###############################################################################
# Bedrock Guardrail
###############################################################################

module "production_guardrail" {
  source = "../../modules/bedrock-guardrails"

  name        = "customer-chatbot-production"
  description = "Production guardrail for the customer-facing AI assistant. Enforces content safety, PII protection, and topic restrictions."

  # ---------------------------------------------------------------------------
  # Content policy: HIGH on harmful categories; PROMPT_ATTACK only on input
  # because prompt injection originates in user input, not model output.
  # ---------------------------------------------------------------------------
  content_policy = {
    sexual = {
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    violence = {
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    hate = {
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    insults = {
      input_strength  = "MEDIUM"
      output_strength = "MEDIUM"
    }
    misconduct = {
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    prompt_attack = {
      input_strength  = "HIGH"
      output_strength = "NONE"
    }
  }

  # ---------------------------------------------------------------------------
  # PII detection
  #   BLOCK:     Credentials and financial identifiers must never transit the
  #              AI layer; the entire request/response is rejected.
  #   ANONYMIZE: Contact information is replaced with placeholder tokens so the
  #              model can still reason about the structure of the conversation
  #              without retaining real values.
  # ---------------------------------------------------------------------------
  pii_entities = [
    # Credentials. always block
    { type = "US_SOCIAL_SECURITY_NUMBER", action = "BLOCK" },
    { type = "CREDIT_DEBIT_CARD_NUMBER", action = "BLOCK" },
    { type = "CREDIT_DEBIT_CARD_CVV", action = "BLOCK" },
    { type = "CREDIT_DEBIT_CARD_EXPIRY", action = "BLOCK" },
    { type = "AWS_ACCESS_KEY", action = "BLOCK" },
    { type = "AWS_SECRET_KEY", action = "BLOCK" },
    { type = "PASSWORD", action = "BLOCK" },
    { type = "PIN", action = "BLOCK" },

    # Contact and identity. anonymize
    { type = "NAME", action = "ANONYMIZE" },
    { type = "EMAIL", action = "ANONYMIZE" },
    { type = "PHONE", action = "ANONYMIZE" },

    # Additional financial identifiers. anonymize
    { type = "US_BANK_ACCOUNT_NUMBER", action = "ANONYMIZE" },
    { type = "US_BANK_ROUTING_NUMBER", action = "ANONYMIZE" },
    { type = "INTERNATIONAL_BANK_ACCOUNT_NUMBER", action = "ANONYMIZE" },
  ]

  # ---------------------------------------------------------------------------
  # Custom regex: internal employee IDs
  # Pattern matches strings like EMP123456 used in internal tooling. These
  # should never appear in customer-facing AI outputs.
  # ---------------------------------------------------------------------------
  regex_filters = [
    {
      name        = "internal-employee-id"
      description = "Detects internal employee IDs in the format EMP followed by exactly 6 digits."
      pattern     = "EMP\\d{6}"
      action      = "ANONYMIZE"
    },
    {
      name        = "internal-ticket-id"
      description = "Detects internal support ticket identifiers in the format TICK-XXXXXXXX."
      pattern     = "TICK-[A-Z0-9]{8}"
      action      = "ANONYMIZE"
    },
  ]

  # ---------------------------------------------------------------------------
  # Denied topics
  # Bedrock trains a classifier from the definition and examples; providing
  # diverse, realistic examples significantly improves detection accuracy.
  # ---------------------------------------------------------------------------
  denied_topics = [
    {
      name       = "investment_advice"
      definition = "Providing specific recommendations to buy, sell, or hold financial instruments including stocks, bonds, cryptocurrency, options, or any other investment vehicle."
      examples = [
        "Should I buy Apple stock right now?",
        "Is Bitcoin a good investment for retirement?",
        "What stocks should I add to my portfolio?",
      ]
    },
    {
      name       = "legal_advice"
      definition = "Providing legal counsel, interpretation of laws or regulations as they apply to a specific situation, or recommendations that substitute for advice from a licensed attorney."
      examples = [
        "Can I sue my landlord for not fixing the heating?",
        "Is my employer required to pay overtime in California?",
        "How should I structure my will to avoid probate?",
      ]
    },
  ]

  # ---------------------------------------------------------------------------
  # Word filters: internal terminology that must not surface to customers
  # ---------------------------------------------------------------------------
  word_filters = [
    "internal-only",
    "confidential",
    "do not share",
    "not for distribution",
    "draft only",
  ]

  # Enable AWS-managed PROFANITY list in addition to custom words.
  enable_profanity_filter = true

  # ---------------------------------------------------------------------------
  # Contextual grounding: enforce response accuracy for RAG use cases
  #   grounding_threshold = 0.7. blocks responses poorly grounded in sources
  #   relevance_threshold = 0.8. blocks responses that drift from the query
  # ---------------------------------------------------------------------------
  contextual_grounding = {
    grounding_threshold = 0.7
    relevance_threshold = 0.8
  }

  # User-facing block messages
  blocked_input_messaging   = "Your message contains content that cannot be processed. Please revise your request and try again, or contact support if you believe this is an error."
  blocked_outputs_messaging = "The response was withheld because it contained content that does not meet our content policy. Please rephrase your question or contact support."

  # Publish an immutable version so production traffic pins to a known snapshot.
  enable_versioning = true

  # Grant the application role permission to invoke models with this guardrail.
  principal_arns = [aws_iam_role.app.arn]

  tags = local.common_tags
}

###############################################################################
# Attach the generated IAM policy to the application role
###############################################################################

resource "aws_iam_role_policy" "bedrock_access" {
  name   = "bedrock-guardrail-invoke"
  role   = aws_iam_role.app.name
  policy = module.production_guardrail.invoke_policy_json
}

###############################################################################
# Outputs
###############################################################################

output "guardrail_id" {
  description = "Guardrail ID to pass as guardrailIdentifier in Bedrock API calls."
  value       = module.production_guardrail.guardrail_id
}

output "guardrail_arn" {
  description = "Guardrail ARN."
  value       = module.production_guardrail.guardrail_arn
}

output "guardrail_version" {
  description = "Pinned version number for production API calls."
  value       = module.production_guardrail.guardrail_version
}

output "guardrail_version_arn" {
  description = "Versioned ARN for use in IAM policies and SDK configuration."
  value       = module.production_guardrail.guardrail_version_arn
}
