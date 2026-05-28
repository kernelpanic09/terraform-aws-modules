variable "name" {
  description = "Name of the Bedrock guardrail. Must be unique within the AWS account and region."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}[a-zA-Z0-9]$", var.name)) || length(var.name) == 1
    error_message = "Guardrail name must be 1-64 characters, start and end with alphanumeric characters, and contain only letters, digits, hyphens, or underscores."
  }
}

variable "description" {
  description = "Human-readable description of the guardrail and its intended use."
  type        = string
  default     = ""

  validation {
    condition     = length(var.description) <= 200
    error_message = "Description must be 200 characters or fewer."
  }
}

# ---------------------------------------------------------------------------
# Content policy filters
# ---------------------------------------------------------------------------

variable "content_policy" {
  description = <<-EOT
    Content policy filter configuration. Each filter type accepts an input_strength
    and output_strength. Valid strengths are NONE, LOW, MEDIUM, HIGH.

    Filter types:
      - sexual:         Content of a sexual nature.
      - violence:       Violent or graphic content.
      - hate:           Hateful or discriminatory content.
      - insults:        Insulting or harassing content.
      - misconduct:     Illegal activity or professional misconduct.
      - prompt_attack:  Prompt injection or jailbreak attempts.
  EOT
  type = object({
    sexual = optional(object({
      input_strength  = optional(string, "HIGH")
      output_strength = optional(string, "HIGH")
    }), { input_strength = "HIGH", output_strength = "HIGH" })
    violence = optional(object({
      input_strength  = optional(string, "HIGH")
      output_strength = optional(string, "HIGH")
    }), { input_strength = "HIGH", output_strength = "HIGH" })
    hate = optional(object({
      input_strength  = optional(string, "HIGH")
      output_strength = optional(string, "HIGH")
    }), { input_strength = "HIGH", output_strength = "HIGH" })
    insults = optional(object({
      input_strength  = optional(string, "HIGH")
      output_strength = optional(string, "HIGH")
    }), { input_strength = "HIGH", output_strength = "HIGH" })
    misconduct = optional(object({
      input_strength  = optional(string, "HIGH")
      output_strength = optional(string, "HIGH")
    }), { input_strength = "HIGH", output_strength = "HIGH" })
    prompt_attack = optional(object({
      input_strength  = optional(string, "HIGH")
      output_strength = optional(string, "NONE")
    }), { input_strength = "HIGH", output_strength = "NONE" })
  })
  default = {}

  validation {
    condition = alltrue([
      for strength in [
        var.content_policy.sexual.input_strength,
        var.content_policy.sexual.output_strength,
        var.content_policy.violence.input_strength,
        var.content_policy.violence.output_strength,
        var.content_policy.hate.input_strength,
        var.content_policy.hate.output_strength,
        var.content_policy.insults.input_strength,
        var.content_policy.insults.output_strength,
        var.content_policy.misconduct.input_strength,
        var.content_policy.misconduct.output_strength,
        var.content_policy.prompt_attack.input_strength,
        var.content_policy.prompt_attack.output_strength,
      ] : contains(["NONE", "LOW", "MEDIUM", "HIGH"], strength)
    ])
    error_message = "All content policy filter strengths must be one of: NONE, LOW, MEDIUM, HIGH."
  }
}

# ---------------------------------------------------------------------------
# PII detection
# ---------------------------------------------------------------------------

variable "pii_entities" {
  description = <<-EOT
    List of PII entity configurations. Each entry specifies a PII entity type and the
    action to take when detected.

    Supported types:
      ADDRESS, AGE, AWS_ACCESS_KEY, AWS_SECRET_KEY, CA_HEALTH_NUMBER,
      CA_SOCIAL_INSURANCE_NUMBER, CREDIT_DEBIT_CARD_CVV, CREDIT_DEBIT_CARD_EXPIRY,
      CREDIT_DEBIT_CARD_NUMBER, DRIVER_ID, EMAIL, INTERNATIONAL_BANK_ACCOUNT_NUMBER,
      IP_ADDRESS, LICENSE_PLATE, MAC_ADDRESS, NAME, PASSWORD, PHONE, PIN,
      SWIFT_CODE, UK_NATIONAL_HEALTH_SERVICE_NUMBER, UK_NATIONAL_INSURANCE_NUMBER,
      UK_UNIQUE_TAXPAYER_REFERENCE_NUMBER, URL, USERNAME, US_BANK_ACCOUNT_NUMBER,
      US_BANK_ROUTING_NUMBER, US_INDIVIDUAL_TAX_IDENTIFICATION_NUMBER,
      US_PASSPORT_NUMBER, US_SOCIAL_SECURITY_NUMBER, VEHICLE_IDENTIFICATION_NUMBER

    Actions:
      BLOCK      - Deny the request or response when this PII type is detected.
      ANONYMIZE  - Replace detected PII with a placeholder token.
  EOT
  type = list(object({
    type   = string
    action = string
  }))
  default = []

  validation {
    condition = alltrue([
      for e in var.pii_entities : contains([
        "ADDRESS", "AGE", "AWS_ACCESS_KEY", "AWS_SECRET_KEY",
        "CA_HEALTH_NUMBER", "CA_SOCIAL_INSURANCE_NUMBER",
        "CREDIT_DEBIT_CARD_CVV", "CREDIT_DEBIT_CARD_EXPIRY",
        "CREDIT_DEBIT_CARD_NUMBER", "DRIVER_ID", "EMAIL",
        "INTERNATIONAL_BANK_ACCOUNT_NUMBER", "IP_ADDRESS",
        "LICENSE_PLATE", "MAC_ADDRESS", "NAME", "PASSWORD",
        "PHONE", "PIN", "SWIFT_CODE",
        "UK_NATIONAL_HEALTH_SERVICE_NUMBER",
        "UK_NATIONAL_INSURANCE_NUMBER",
        "UK_UNIQUE_TAXPAYER_REFERENCE_NUMBER", "URL", "USERNAME",
        "US_BANK_ACCOUNT_NUMBER", "US_BANK_ROUTING_NUMBER",
        "US_INDIVIDUAL_TAX_IDENTIFICATION_NUMBER",
        "US_PASSPORT_NUMBER", "US_SOCIAL_SECURITY_NUMBER",
        "VEHICLE_IDENTIFICATION_NUMBER",
      ], e.type)
    ])
    error_message = "Each pii_entities entry must have a type from the Bedrock-supported PII entity list."
  }

  validation {
    condition = alltrue([
      for e in var.pii_entities : contains(["BLOCK", "ANONYMIZE"], e.action)
    ])
    error_message = "Each pii_entities action must be either BLOCK or ANONYMIZE."
  }
}

# ---------------------------------------------------------------------------
# Custom regex filters
# ---------------------------------------------------------------------------

variable "regex_filters" {
  description = <<-EOT
    List of custom regex-based sensitive data filters. Each entry must have a unique
    name, a valid RE2-compatible regular expression pattern, and an action.

    Fields:
      name        - Unique identifier for this regex filter (alphanumeric, hyphens, underscores).
      description - Optional human-readable description.
      pattern     - RE2-compatible regular expression to match against input/output.
      action      - BLOCK or ANONYMIZE.
  EOT
  type = list(object({
    name        = string
    description = optional(string, "")
    pattern     = string
    action      = string
  }))
  default = []

  validation {
    condition = alltrue([
      for f in var.regex_filters : can(regex(f.pattern, ""))
    ])
    error_message = "All regex_filters patterns must be valid regular expressions."
  }

  validation {
    condition = alltrue([
      for f in var.regex_filters : contains(["BLOCK", "ANONYMIZE"], f.action)
    ])
    error_message = "Each regex_filters action must be either BLOCK or ANONYMIZE."
  }

  validation {
    condition = alltrue([
      for f in var.regex_filters : can(regex("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,98}$", f.name))
    ])
    error_message = "Each regex_filters name must start with an alphanumeric character and contain only letters, digits, hyphens, or underscores (max 100 characters)."
  }
}

# ---------------------------------------------------------------------------
# Denied topics
# ---------------------------------------------------------------------------

variable "denied_topics" {
  description = <<-EOT
    List of topics the guardrail should refuse to engage with. Bedrock uses these
    definitions (and optional examples) to train a topic classifier.

    Fields:
      name        - Unique topic name (no spaces; use underscores).
      definition  - Concise definition of what the topic covers.
      examples    - Optional list of example phrases that belong to this topic.
                    Providing 2-5 diverse examples improves detection accuracy.
  EOT
  type = list(object({
    name       = string
    definition = string
    examples   = optional(list(string), [])
  }))
  default = []

  validation {
    condition = alltrue([
      for t in var.denied_topics : length(t.name) >= 1 && length(t.name) <= 100
    ])
    error_message = "Each denied_topics name must be between 1 and 100 characters."
  }

  validation {
    condition = alltrue([
      for t in var.denied_topics : length(t.definition) >= 1 && length(t.definition) <= 200
    ])
    error_message = "Each denied_topics definition must be between 1 and 200 characters."
  }

  validation {
    condition = alltrue([
      for t in var.denied_topics : length(t.examples) <= 5
    ])
    error_message = "Each denied_topics entry may have at most 5 examples."
  }
}

# ---------------------------------------------------------------------------
# Word filters
# ---------------------------------------------------------------------------

variable "word_filters" {
  description = <<-EOT
    List of custom words or short phrases to block. Matching is case-insensitive and
    performed as whole-word or phrase matching. Include terms specific to your
    organization that should never appear in AI inputs or outputs.
  EOT
  type    = list(string)
  default = []

  validation {
    condition = alltrue([
      for w in var.word_filters : length(w) >= 1 && length(w) <= 3000
    ])
    error_message = "Each word_filter entry must be between 1 and 3000 characters."
  }
}

variable "enable_profanity_filter" {
  description = "Enable the AWS-managed PROFANITY word list in addition to any custom word filters."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Contextual grounding
# ---------------------------------------------------------------------------

variable "contextual_grounding" {
  description = <<-EOT
    Contextual grounding policy thresholds for RAG and summarization use cases.
    Thresholds range from 0.0 (permissive) to 0.99 (strict).

    Fields:
      grounding_threshold  - Minimum grounding score; responses with a lower score
                             are blocked. Measures how well the response is grounded
                             in the provided source content.
      relevance_threshold  - Minimum relevance score; responses with a lower score
                             are blocked. Measures how relevant the response is to
                             the user query.

    Set either threshold to null to disable that check. Both default to null
    (contextual grounding disabled).
  EOT
  type = object({
    grounding_threshold = optional(number, null)
    relevance_threshold = optional(number, null)
  })
  default = {
    grounding_threshold = null
    relevance_threshold = null
  }

  validation {
    condition = (
      var.contextual_grounding.grounding_threshold == null ||
      (var.contextual_grounding.grounding_threshold >= 0.0 &&
      var.contextual_grounding.grounding_threshold <= 0.99)
    )
    error_message = "contextual_grounding.grounding_threshold must be between 0.0 and 0.99, or null to disable."
  }

  validation {
    condition = (
      var.contextual_grounding.relevance_threshold == null ||
      (var.contextual_grounding.relevance_threshold >= 0.0 &&
      var.contextual_grounding.relevance_threshold <= 0.99)
    )
    error_message = "contextual_grounding.relevance_threshold must be between 0.0 and 0.99, or null to disable."
  }
}

# ---------------------------------------------------------------------------
# User-facing block messages
# ---------------------------------------------------------------------------

variable "blocked_input_messaging" {
  description = <<-EOT
    Message returned to users when their input is blocked by the guardrail.
    Keep this message clear and non-technical so users understand why the
    request was rejected without exposing internal policy details.
  EOT
  type    = string
  default = "Your request contains content that cannot be processed. Please revise your input and try again."

  validation {
    condition     = length(var.blocked_input_messaging) >= 1 && length(var.blocked_input_messaging) <= 500
    error_message = "blocked_input_messaging must be between 1 and 500 characters."
  }
}

variable "blocked_outputs_messaging" {
  description = <<-EOT
    Message returned to users when the model output is blocked by the guardrail.
    Keep this message clear and non-technical so users understand why the
    response was withheld without exposing internal policy details.
  EOT
  type    = string
  default = "The response was blocked because it contains content that cannot be shown. Please rephrase your question."

  validation {
    condition     = length(var.blocked_outputs_messaging) >= 1 && length(var.blocked_outputs_messaging) <= 500
    error_message = "blocked_outputs_messaging must be between 1 and 500 characters."
  }
}

# ---------------------------------------------------------------------------
# Encryption
# ---------------------------------------------------------------------------

variable "kms_key_arn" {
  description = <<-EOT
    ARN of an AWS KMS key used to encrypt the guardrail configuration at rest.
    The key must grant the Bedrock service principal kms:Encrypt, kms:Decrypt,
    and kms:GenerateDataKey permissions. Leave null to use the default
    AWS-managed key for Bedrock.
  EOT
  type    = string
  default = null

  validation {
    condition = (
      var.kms_key_arn == null ||
      can(regex("^arn:aws(-[a-z]+)*:kms:[a-z0-9-]+:[0-9]{12}:key/[a-zA-Z0-9-]+$", var.kms_key_arn))
    )
    error_message = "kms_key_arn must be a valid KMS key ARN (arn:aws:kms:<region>:<account>:key/<key-id>) or null."
  }
}

# ---------------------------------------------------------------------------
# Versioning
# ---------------------------------------------------------------------------

variable "enable_versioning" {
  description = <<-EOT
    When true, publishes an immutable version snapshot of the guardrail after
    creation or update via aws_bedrock_guardrail_version. Reference this version
    ARN in production to ensure deterministic behaviour even if the DRAFT is
    later modified.
  EOT
  type    = bool
  default = true
}

# ---------------------------------------------------------------------------
# IAM policy document
# ---------------------------------------------------------------------------

variable "principal_arns" {
  description = <<-EOT
    List of IAM principal ARNs (roles, users, or assumed-role sessions) that
    should be granted permission to invoke Bedrock models with this guardrail.
    The module outputs a rendered IAM policy document JSON that callers can
    attach to their roles -- no IAM resources are created by this module.

    Leave empty to skip generating the policy document.
  EOT
  type    = list(string)
  default = []

  validation {
    condition = alltrue([
      for arn in var.principal_arns : can(regex("^arn:aws(-[a-z]+)*:iam::[0-9]{12}:(role|user|assumed-role)/.+$", arn))
    ])
    error_message = "Each principal_arns entry must be a valid IAM role, user, or assumed-role ARN."
  }
}

# ---------------------------------------------------------------------------
# Tags
# ---------------------------------------------------------------------------

variable "tags" {
  description = "Map of tags to apply to all resources created by this module."
  type        = map(string)
  default     = {}
}
