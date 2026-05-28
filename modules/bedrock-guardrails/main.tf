###############################################################################
# bedrock-guardrails module
#
# Provisions an AWS Bedrock Guardrail with:
#   - Content policy filters (SEXUAL, VIOLENCE, HATE, INSULTS, MISCONDUCT, PROMPT_ATTACK)
#   - PII entity detection and action enforcement
#   - Custom regex-based sensitive data filters
#   - Denied topic classifiers
#   - Custom and managed (PROFANITY) word filters
#   - Contextual grounding policy (optional)
#   - Optional immutable version snapshot
#   - IAM policy document output for downstream attachment
###############################################################################

locals {
  # Build the list of content filter config blocks. Bedrock requires one block
  # per (filter_type, input_strength, output_strength) combination; we always
  # emit all six types because strengths can be set to NONE to effectively
  # disable a filter while still satisfying the resource schema.
  content_filters = [
    {
      type            = "SEXUAL"
      input_strength  = var.content_policy.sexual.input_strength
      output_strength = var.content_policy.sexual.output_strength
    },
    {
      type            = "VIOLENCE"
      input_strength  = var.content_policy.violence.input_strength
      output_strength = var.content_policy.violence.output_strength
    },
    {
      type            = "HATE"
      input_strength  = var.content_policy.hate.input_strength
      output_strength = var.content_policy.hate.output_strength
    },
    {
      type            = "INSULTS"
      input_strength  = var.content_policy.insults.input_strength
      output_strength = var.content_policy.insults.output_strength
    },
    {
      type            = "MISCONDUCT"
      input_strength  = var.content_policy.misconduct.input_strength
      output_strength = var.content_policy.misconduct.output_strength
    },
    {
      type            = "PROMPT_ATTACK"
      input_strength  = var.content_policy.prompt_attack.input_strength
      output_strength = var.content_policy.prompt_attack.output_strength
    },
  ]

  # Whether contextual grounding should be included in the guardrail. At least
  # one threshold must be non-null.
  enable_contextual_grounding = (
    var.contextual_grounding.grounding_threshold != null ||
    var.contextual_grounding.relevance_threshold != null
  )

  # Contextual grounding filter list; only include entries whose threshold is set.
  contextual_grounding_filters = [
    for entry in [
      {
        type      = "GROUNDING"
        threshold = var.contextual_grounding.grounding_threshold
      },
      {
        type      = "RELEVANCE"
        threshold = var.contextual_grounding.relevance_threshold
      },
    ] : entry if entry.threshold != null
  ]

  # Whether any word-level filtering is configured.
  enable_word_policy = length(var.word_filters) > 0 || var.enable_profanity_filter

  # Whether PII or regex filtering is configured.
  enable_sensitive_info_policy = length(var.pii_entities) > 0 || length(var.regex_filters) > 0

  # Whether denied topics are configured.
  enable_topic_policy = length(var.denied_topics) > 0
}

###############################################################################
# Guardrail
###############################################################################

resource "aws_bedrock_guardrail" "this" {
  name                      = var.name
  description               = var.description
  blocked_input_messaging   = var.blocked_input_messaging
  blocked_outputs_messaging = var.blocked_outputs_messaging
  kms_key_arn               = var.kms_key_arn

  # ---------------------------------------------------------------------------
  # Content policy
  # ---------------------------------------------------------------------------
  content_policy_config {
    dynamic "filters_config" {
      for_each = local.content_filters
      content {
        type            = filters_config.value.type
        input_strength  = filters_config.value.input_strength
        output_strength = filters_config.value.output_strength
      }
    }
  }

  # ---------------------------------------------------------------------------
  # Sensitive information policy (PII + custom regex)
  # ---------------------------------------------------------------------------
  dynamic "sensitive_information_policy_config" {
    for_each = local.enable_sensitive_info_policy ? [1] : []
    content {
      dynamic "pii_entities_config" {
        for_each = var.pii_entities
        content {
          type   = pii_entities_config.value.type
          action = pii_entities_config.value.action
        }
      }

      dynamic "regexes_config" {
        for_each = var.regex_filters
        content {
          name        = regexes_config.value.name
          description = regexes_config.value.description
          pattern     = regexes_config.value.pattern
          action      = regexes_config.value.action
        }
      }
    }
  }

  # ---------------------------------------------------------------------------
  # Topic policy (denied topics)
  # ---------------------------------------------------------------------------
  dynamic "topic_policy_config" {
    for_each = local.enable_topic_policy ? [1] : []
    content {
      dynamic "topics_config" {
        for_each = var.denied_topics
        content {
          name       = topics_config.value.name
          definition = topics_config.value.definition
          examples   = topics_config.value.examples
          type       = "DENY"
        }
      }
    }
  }

  # ---------------------------------------------------------------------------
  # Word policy (custom words + managed lists)
  # ---------------------------------------------------------------------------
  dynamic "word_policy_config" {
    for_each = local.enable_word_policy ? [1] : []
    content {
      dynamic "words_config" {
        for_each = var.word_filters
        content {
          text = words_config.value
        }
      }

      dynamic "managed_word_lists_config" {
        for_each = var.enable_profanity_filter ? ["PROFANITY"] : []
        content {
          type = managed_word_lists_config.value
        }
      }
    }
  }

  # ---------------------------------------------------------------------------
  # Contextual grounding policy
  # ---------------------------------------------------------------------------
  dynamic "contextual_grounding_policy_config" {
    for_each = local.enable_contextual_grounding ? [1] : []
    content {
      dynamic "filters_config" {
        for_each = local.contextual_grounding_filters
        content {
          type      = filters_config.value.type
          threshold = filters_config.value.threshold
        }
      }
    }
  }

  tags = var.tags
}

###############################################################################
# Guardrail version (immutable snapshot for production references)
###############################################################################

resource "aws_bedrock_guardrail_version" "this" {
  count = var.enable_versioning ? 1 : 0

  guardrail_arn = aws_bedrock_guardrail.this.guardrail_arn
  description   = "Versioned snapshot of guardrail ${var.name} managed by Terraform."

  # Re-publish whenever the guardrail itself changes so the version always
  # reflects the current DRAFT configuration.
  lifecycle {
    replace_triggered_by = [aws_bedrock_guardrail.this]
  }
}

###############################################################################
# IAM policy document
#
# This data source renders a policy that grants principals permission to invoke
# Bedrock models and apply this specific guardrail. No IAM resources are created
# here; callers attach the JSON to their own aws_iam_policy or
# aws_iam_role_policy resources.
###############################################################################

data "aws_iam_policy_document" "invoke_with_guardrail" {
  count = length(var.principal_arns) > 0 ? 1 : 0

  statement {
    sid    = "AllowBedrockInvokeWithGuardrail"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = var.principal_arns
    }

    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]

    resources = ["arn:aws:bedrock:*::foundation-model/*"]
  }

  statement {
    sid    = "AllowApplyGuardrail"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = var.principal_arns
    }

    actions = [
      "bedrock:ApplyGuardrail",
    ]

    resources = [aws_bedrock_guardrail.this.guardrail_arn]

    condition {
      test     = "StringEquals"
      variable = "bedrock:guardrailId"
      values   = [aws_bedrock_guardrail.this.guardrail_id]
    }
  }
}
