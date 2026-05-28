# ------------------------------------------------------------------------------
# Core
# ------------------------------------------------------------------------------

variable "name" {
  description = "Name prefix applied to all resources created by this module. Used as the S3 bucket name and as a prefix for CloudFront, WAF, and IAM resources."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.name))
    error_message = "Name must be 3-63 characters, lowercase alphanumeric and hyphens, and must not start or end with a hyphen (follows S3 bucket naming rules)."
  }
}

variable "tags" {
  description = "Map of additional tags to apply to all taggable resources. Merged with module-managed tags (ManagedBy, Module)."
  type        = map(string)
  default     = {}
}

# ------------------------------------------------------------------------------
# Custom Domain / ACM
# ------------------------------------------------------------------------------

variable "domain_name" {
  description = "Primary custom domain name for the CloudFront distribution (e.g. example.com). When set, an ACM certificate ARN must also be supplied. Leave null to use the default CloudFront domain."
  type        = string
  default     = null

  validation {
    condition     = var.domain_name == null || can(regex("^([a-zA-Z0-9-]+\\.)+[a-zA-Z]{2,}$", var.domain_name))
    error_message = "domain_name must be a valid fully-qualified domain name or null."
  }
}

variable "subject_alternative_names" {
  description = "Additional domain names (SANs) for the CloudFront distribution. Only used when domain_name is set. Useful for adding www. variants."
  type        = list(string)
  default     = []
}

variable "acm_certificate_arn" {
  description = "ARN of an ACM certificate in us-east-1 to attach to the CloudFront distribution. Required when domain_name is set. CloudFront only accepts certificates from us-east-1 regardless of the distribution's origin region."
  type        = string
  default     = null

  validation {
    condition     = var.acm_certificate_arn == null || can(regex("^arn:aws:acm:us-east-1:", var.acm_certificate_arn))
    error_message = "acm_certificate_arn must be an ACM certificate ARN in us-east-1 (CloudFront requirement) or null."
  }
}

# ------------------------------------------------------------------------------
# CloudFront Distribution
# ------------------------------------------------------------------------------

variable "price_class" {
  description = "CloudFront price class. PriceClass_100 uses only North America and Europe edge locations (cheapest). PriceClass_200 adds Asia Pacific and Middle East. PriceClass_All uses all edge locations globally."
  type        = string
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.price_class)
    error_message = "price_class must be one of: PriceClass_100, PriceClass_200, PriceClass_All."
  }
}

variable "default_ttl" {
  description = "Default TTL in seconds for cached objects when the origin does not send Cache-Control or Expires headers. Defaults to 1 day."
  type        = number
  default     = 86400

  validation {
    condition     = var.default_ttl >= 0 && var.default_ttl <= 31536000
    error_message = "default_ttl must be between 0 and 31536000 seconds (1 year)."
  }
}

variable "min_ttl" {
  description = "Minimum TTL in seconds for cached objects. Objects will not be cached for less than this value even if Cache-Control directives request it."
  type        = number
  default     = 0

  validation {
    condition     = var.min_ttl >= 0
    error_message = "min_ttl must be >= 0."
  }
}

variable "max_ttl" {
  description = "Maximum TTL in seconds for cached objects. Objects will not be cached longer than this even if Cache-Control directives request it. Defaults to 1 year."
  type        = number
  default     = 31536000

  validation {
    condition     = var.max_ttl >= 0 && var.max_ttl <= 31536000
    error_message = "max_ttl must be between 0 and 31536000 seconds (1 year)."
  }
}

variable "custom_error_responses" {
  description = <<-EOT
    List of custom error response configurations for the CloudFront distribution.
    Defaults to SPA-friendly rewrites: HTTP 403 and 404 are both served as /index.html with a 200 status code.
    Set to [] to disable all custom error responses.

    Each object supports:
      error_code            - (required) HTTP status code returned by the origin (e.g. 403, 404).
      response_code         - (required) HTTP status code sent to viewers.
      response_page_path    - (required) Path to the response document (e.g. /index.html).
      error_caching_min_ttl - (optional) Seconds to cache the error response. Defaults to 10.
  EOT
  type = list(object({
    error_code            = number
    response_code         = number
    response_page_path    = string
    error_caching_min_ttl = optional(number, 10)
  }))
  default = [
    {
      error_code            = 403
      response_code         = 200
      response_page_path    = "/index.html"
      error_caching_min_ttl = 10
    },
    {
      error_code            = 404
      response_code         = 200
      response_page_path    = "/index.html"
      error_caching_min_ttl = 10
    },
  ]
}

# ------------------------------------------------------------------------------
# Security Headers
# ------------------------------------------------------------------------------

variable "enable_security_headers" {
  description = "Attach a CloudFront Response Headers Policy that sets HSTS, X-Content-Type-Options, X-Frame-Options, and Referrer-Policy security headers. Recommended for production."
  type        = bool
  default     = true
}

variable "hsts_max_age" {
  description = "HSTS max-age directive in seconds. Only used when enable_security_headers = true. Defaults to 31536000 (1 year)."
  type        = number
  default     = 31536000

  validation {
    condition     = var.hsts_max_age >= 0
    error_message = "hsts_max_age must be >= 0."
  }
}

# ------------------------------------------------------------------------------
# S3 Bucket
# ------------------------------------------------------------------------------

variable "enable_versioning" {
  description = "Enable S3 object versioning on the static site bucket. Useful for rollback and audit. Note: versioned buckets require extra lifecycle rules to expire old versions and keep costs under control."
  type        = bool
  default     = true
}

variable "encryption_type" {
  description = "Server-side encryption algorithm for the S3 bucket. Use 'AES256' for SSE-S3 (no extra cost) or 'aws:kms' to use a customer-managed KMS key. When 'aws:kms' is selected, kms_key_id is required."
  type        = string
  default     = "AES256"

  validation {
    condition     = contains(["AES256", "aws:kms"], var.encryption_type)
    error_message = "encryption_type must be 'AES256' (SSE-S3) or 'aws:kms' (SSE-KMS)."
  }
}

variable "kms_key_id" {
  description = "ARN or alias of the KMS key to use for S3 SSE-KMS encryption. Required when encryption_type = 'aws:kms'. Leave null for SSE-S3."
  type        = string
  default     = null
}

variable "lifecycle_rules" {
  description = <<-EOT
    List of S3 lifecycle rules to apply to the bucket. Useful for expiring old object versions
    and transitioning infrequently accessed content to cheaper storage classes.

    Each object supports:
      id                            - (required) Unique identifier for the rule.
      enabled                       - (optional) Whether the rule is active. Defaults to true.
      prefix                        - (optional) Key prefix to which the rule applies. Empty string applies to all objects.
      expiration_days               - (optional) Days after object creation to permanently delete the object.
      noncurrent_expiration_days    - (optional) Days after becoming noncurrent (versioning) to delete the version.
      transition_days               - (optional) Days after object creation to transition to transition_storage_class.
      transition_storage_class      - (optional) Target storage class for the transition. One of: STANDARD_IA, ONEZONE_IA, INTELLIGENT_TIERING, GLACIER, DEEP_ARCHIVE, GLACIER_IR.
      noncurrent_transition_days    - (optional) Days after becoming noncurrent to transition to noncurrent_storage_class.
      noncurrent_storage_class      - (optional) Target storage class for noncurrent version transitions.
  EOT
  type = list(object({
    id                         = string
    enabled                    = optional(bool, true)
    prefix                     = optional(string, "")
    expiration_days            = optional(number, null)
    noncurrent_expiration_days = optional(number, null)
    transition_days            = optional(number, null)
    transition_storage_class   = optional(string, null)
    noncurrent_transition_days = optional(number, null)
    noncurrent_storage_class   = optional(string, null)
  }))
  default = [
    {
      id                         = "expire-old-versions"
      enabled                    = true
      prefix                     = ""
      noncurrent_expiration_days = 30
    },
  ]

  validation {
    condition = alltrue([
      for r in var.lifecycle_rules :
      r.transition_storage_class == null ||
      contains(["STANDARD_IA", "ONEZONE_IA", "INTELLIGENT_TIERING", "GLACIER", "DEEP_ARCHIVE", "GLACIER_IR"], r.transition_storage_class)
    ])
    error_message = "transition_storage_class must be one of: STANDARD_IA, ONEZONE_IA, INTELLIGENT_TIERING, GLACIER, DEEP_ARCHIVE, GLACIER_IR."
  }

  validation {
    condition = alltrue([
      for r in var.lifecycle_rules :
      r.noncurrent_storage_class == null ||
      contains(["STANDARD_IA", "ONEZONE_IA", "INTELLIGENT_TIERING", "GLACIER", "DEEP_ARCHIVE", "GLACIER_IR"], r.noncurrent_storage_class)
    ])
    error_message = "noncurrent_storage_class must be one of: STANDARD_IA, ONEZONE_IA, INTELLIGENT_TIERING, GLACIER, DEEP_ARCHIVE, GLACIER_IR."
  }
}

# ------------------------------------------------------------------------------
# WAF
# ------------------------------------------------------------------------------

variable "enable_waf" {
  description = "Create and associate an AWS WAFv2 Web ACL with the CloudFront distribution. Includes AWSManagedRulesCommonRuleSet, AWSManagedRulesKnownBadInputsRuleSet, and a configurable rate-limiting rule. WAF ACLs for CloudFront must be created in us-east-1."
  type        = bool
  default     = false
}

variable "waf_rate_limit" {
  description = "Maximum number of requests allowed from a single IP within any 5-minute window before WAF blocks that IP. Only used when enable_waf = true. AWS minimum is 100."
  type        = number
  default     = 2000

  validation {
    condition     = var.waf_rate_limit >= 100
    error_message = "waf_rate_limit must be >= 100 (AWS WAFv2 minimum for rate-based rules)."
  }
}

variable "waf_block_mode" {
  description = "When true, managed WAF rule groups are set to Block mode. When false, rules are set to Count mode (useful for evaluating rule impact before enforcing). Only used when enable_waf = true."
  type        = bool
  default     = true
}
