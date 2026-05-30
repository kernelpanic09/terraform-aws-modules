variable "name" {
  description = "Name prefix for all resources created by this module."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,28}[a-z0-9]$", var.name))
    error_message = "name must be 3-30 characters, start with a letter, contain only lowercase letters, numbers, and hyphens, and not end with a hyphen."
  }
}

variable "primary_model" {
  description = "Default Bedrock model ID to use for inference."
  type        = string
  default     = "anthropic.claude-haiku-4-5-20251001-v1:0"
}

variable "fallback_models" {
  description = "Ordered list of Bedrock model IDs to try when the primary model is throttled."
  type        = list(string)
  default     = ["anthropic.claude-3-haiku-20240307-v1:0", "meta.llama3-8b-instruct-v1:0"]

  validation {
    condition     = length(var.fallback_models) <= 3
    error_message = "At most 3 fallback models are supported."
  }
}

variable "enable_caching" {
  description = "Whether to enable prompt response caching in DynamoDB."
  type        = bool
  default     = true
}

variable "cache_ttl_seconds" {
  description = "How long cached responses are retained (seconds). Minimum 60, maximum 86400."
  type        = number
  default     = 3600

  validation {
    condition     = var.cache_ttl_seconds >= 60 && var.cache_ttl_seconds <= 86400
    error_message = "cache_ttl_seconds must be between 60 and 86400."
  }
}

variable "enable_waf" {
  description = "Whether to attach an AWS WAF v2 WebACL with rate limiting and AWS managed rules."
  type        = bool
  default     = false
}

variable "waf_rate_limit" {
  description = "Maximum number of requests per 5-minute window per IP address enforced by WAF."
  type        = number
  default     = 2000

  validation {
    condition     = var.waf_rate_limit >= 100
    error_message = "waf_rate_limit must be at least 100."
  }
}

variable "alarm_emails" {
  description = "List of email addresses to notify for CloudWatch alarms (budget breach, high error rate, throttling)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for e in var.alarm_emails : can(regex("^[^@]+@[^@]+\\.[^@]+$", e))])
    error_message = "All alarm_emails must be valid email addresses."
  }
}

variable "log_retention_days" {
  description = "CloudWatch log retention period in days for Lambda functions."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a valid CloudWatch retention value."
  }
}

variable "kms_deletion_window" {
  description = "Number of days before a deleted KMS key is permanently removed (7-30)."
  type        = number
  default     = 14

  validation {
    condition     = var.kms_deletion_window >= 7 && var.kms_deletion_window <= 30
    error_message = "kms_deletion_window must be between 7 and 30."
  }
}

variable "lambda_memory_mb" {
  description = "Memory size in MB for the proxy Lambda function."
  type        = number
  default     = 512

  validation {
    condition     = var.lambda_memory_mb >= 128 && var.lambda_memory_mb <= 10240
    error_message = "lambda_memory_mb must be between 128 and 10240."
  }
}

variable "lambda_timeout_seconds" {
  description = "Timeout in seconds for the proxy Lambda function (max 900)."
  type        = number
  default     = 60

  validation {
    condition     = var.lambda_timeout_seconds >= 10 && var.lambda_timeout_seconds <= 900
    error_message = "lambda_timeout_seconds must be between 10 and 900."
  }
}

variable "cost_log_retention_days" {
  description = "TTL in days for cost log records in DynamoDB."
  type        = number
  default     = 90

  validation {
    condition     = var.cost_log_retention_days >= 1 && var.cost_log_retention_days <= 365
    error_message = "cost_log_retention_days must be between 1 and 365."
  }
}

variable "error_rate_alarm_threshold_pct" {
  description = "Error rate percentage threshold to trigger the high error rate alarm."
  type        = number
  default     = 5

  validation {
    condition     = var.error_rate_alarm_threshold_pct > 0 && var.error_rate_alarm_threshold_pct <= 100
    error_message = "error_rate_alarm_threshold_pct must be between 1 and 100."
  }
}

variable "throttle_alarm_threshold" {
  description = "Number of Bedrock throttling events per 5-minute period before alerting."
  type        = number
  default     = 10
}

variable "tags" {
  description = "Map of tags to apply to all taggable resources."
  type        = map(string)
  default     = {}
}
