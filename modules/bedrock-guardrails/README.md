# bedrock-guardrails

Terraform module for an AWS Bedrock Guardrail
with a full complement of content safety and compliance controls.

## Features

- **Content policy filters**. Configurable strength (NONE / LOW / MEDIUM / HIGH) on
  input and output for: SEXUAL, VIOLENCE, HATE, INSULTS, MISCONDUCT, PROMPT_ATTACK.
- **PII detection**. Per-entity-type actions (BLOCK or ANONYMIZE) for 30+ PII types
  including SSN, credit card numbers, cloud credentials, and more.
- **Custom regex filters**. RE2-compatible patterns to detect organisation-specific
  sensitive data (employee IDs, internal codes, etc.).
- **Denied topics**. Natural-language topic definitions with optional examples
  that Bedrock uses to train an inline topic classifier.
- **Word filters**. Custom word/phrase blocklist combined with the AWS-managed
  PROFANITY managed word list.
- **Contextual grounding**. Grounding and relevance thresholds for RAG and
  summarisation use cases to reduce hallucinations.
- **Immutable versioning**. Optional `aws_bedrock_guardrail_version` snapshot that
  replaces itself whenever the DRAFT guardrail changes.
- **IAM policy document output**. Rendered JSON that callers can attach to roles;
  no IAM resources are created inside the module.
- **KMS encryption**. Optional customer-managed KMS key for guardrail config at rest.

## Usage

```hcl
module "guardrail" {
  source = "./module"

  name        = "my-production-guardrail"
  description = "Production AI safety guardrail for the customer-facing chatbot."

  content_policy = {
    sexual        = { input_strength = "HIGH",   output_strength = "HIGH"   }
    violence      = { input_strength = "HIGH",   output_strength = "HIGH"   }
    hate          = { input_strength = "HIGH",   output_strength = "HIGH"   }
    insults       = { input_strength = "MEDIUM", output_strength = "MEDIUM" }
    misconduct    = { input_strength = "HIGH",   output_strength = "HIGH"   }
    prompt_attack = { input_strength = "HIGH",   output_strength = "NONE"   }
  }

  pii_entities = [
    { type = "US_SOCIAL_SECURITY_NUMBER", action = "BLOCK"     },
    { type = "CREDIT_DEBIT_CARD_NUMBER",  action = "BLOCK"     },
    { type = "NAME",                      action = "ANONYMIZE" },
    { type = "EMAIL",                     action = "ANONYMIZE" },
  ]

  denied_topics = [
    {
      name       = "investment_advice"
      definition = "Providing specific financial or investment recommendations."
      examples   = ["Should I buy AAPL?", "What stocks should I invest in?"]
    },
  ]

  contextual_grounding = {
    grounding_threshold = 0.7
    relevance_threshold = 0.8
  }

  enable_versioning = true

  tags = {
    Environment = "production"
    Team        = "platform"
  }
}

# Attach the generated policy to a role in the calling module:
resource "aws_iam_role_policy" "bedrock_access" {
  name   = "bedrock-guardrail-access"
  role   = aws_iam_role.app.name
  policy = module.guardrail.invoke_policy_json
}
```

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.5.0 |
| aws | >= 5.50.0 |

## Providers

| Name | Version |
|------|---------|
| aws | >= 5.50.0 |

## Resources

| Name | Type |
|------|------|
| aws_bedrock_guardrail.this | resource |
| aws_bedrock_guardrail_version.this | resource (conditional) |
| data.aws_iam_policy_document.invoke_with_guardrail | data source (conditional) |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| name | Guardrail name (1-64 chars, alphanumeric/hyphens/underscores). | `string` | n/a | yes |
| description | Human-readable description (max 200 chars). | `string` | `""` | no |
| content_policy | Content filter strengths per category. See variable description for details. | `object` | All filters set to HIGH except prompt_attack output (NONE). | no |
| pii_entities | PII types to detect and their actions (BLOCK or ANONYMIZE). | `list(object)` | `[]` | no |
| regex_filters | Custom regex-based sensitive data filters. | `list(object)` | `[]` | no |
| denied_topics | Topics the guardrail should refuse to engage with. | `list(object)` | `[]` | no |
| word_filters | Custom words/phrases to block. | `list(string)` | `[]` | no |
| enable_profanity_filter | Enable the AWS-managed PROFANITY word list. | `bool` | `true` | no |
| contextual_grounding | Grounding and relevance thresholds (0.0-0.99, or null to disable). | `object` | Both null (disabled). | no |
| blocked_input_messaging | User-facing message when input is blocked. | `string` | Generic block message. | no |
| blocked_outputs_messaging | User-facing message when output is blocked. | `string` | Generic block message. | no |
| kms_key_arn | KMS key ARN for guardrail encryption at rest. Null = AWS-managed key. | `string` | `null` | no |
| enable_versioning | Publish an immutable version snapshot. | `bool` | `true` | no |
| principal_arns | IAM principal ARNs to include in the generated invoke policy document. | `list(string)` | `[]` | no |
| tags | Tags to apply to all module resources. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| guardrail_id | Guardrail ID for use as `guardrailIdentifier` in API calls. |
| guardrail_arn | Full ARN of the guardrail. |
| guardrail_version | Published version number. Null if `enable_versioning = false`. |
| guardrail_version_arn | Full ARN including the version number. Null if `enable_versioning = false`. |
| invoke_policy_json | Rendered IAM policy JSON. Null if `principal_arns` is empty. |
| invoke_policy_json_encoded | URL-encoded IAM policy JSON. Null if `principal_arns` is empty. |
| name | Guardrail name as provided. |

## Content Policy Filter Strengths

| Strength | Effect |
|----------|--------|
| NONE | Filter disabled for this direction. |
| LOW | Blocks only high-confidence, egregious violations. |
| MEDIUM | Balances safety with usability. |
| HIGH | Blocks aggressively; may produce false positives on borderline content. |

## Contextual Grounding Notes

Contextual grounding requires the caller to pass a `source` field in the
`guardrailConfig` of the API request containing the retrieved context. Without
a source document, Bedrock cannot compute a grounding score and will skip this
check even if thresholds are set.

Recommended starting values:

- `grounding_threshold`: 0.7 (filters poorly-grounded responses while keeping
  paraphrasing and synthesis)
- `relevance_threshold`: 0.7 (ensures responses address the user query)

## IAM Policy Document

When `principal_arns` is non-empty the module renders a policy document granting:

- `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream` on all
  Bedrock foundation model ARNs.
- `bedrock:ApplyGuardrail` on this guardrail's ARN, conditioned on the
  `bedrock:guardrailId` context key.

Callers attach this JSON to their own `aws_iam_policy` or
`aws_iam_role_policy` resources. This separation keeps IAM management outside
the guardrail module, preventing tight coupling between the policy lifecycle and
the guardrail lifecycle.

## Production Recommendations

1. Pin `enable_versioning = true` and reference `guardrail_version` in
   production API calls so that updates to the DRAFT do not affect live traffic.
2. Supply a customer-managed KMS key via `kms_key_arn` for regulated workloads
   to maintain control over encryption keys and enable audit trails in
   CloudTrail.
3. Set `prompt_attack` input strength to HIGH for any publicly-accessible
   endpoint. Output strength can remain NONE because prompt injection attacks
   originate in input, not output.
4. Review denied topic definitions after changes to the model or application
   domain. Definitions that are too broad cause false positives; definitions
   that are too narrow miss violations.
5. Monitor blocked invocations via Amazon CloudWatch Metrics
   (`AWS/Bedrock` namespace, `GuardrailInvocations` with
   `Action=BLOCKED` dimension) to tune thresholds over time.
