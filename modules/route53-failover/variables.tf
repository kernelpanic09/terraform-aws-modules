# ---------------------------------------------------------------------------
# Core DNS configuration
# ---------------------------------------------------------------------------

variable "domain_name" {
  description = "The apex domain name (e.g. example.com). Used for SNS topic naming and tagging."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9\\-\\.]+[a-z0-9]$", var.domain_name))
    error_message = "domain_name must be a valid DNS label (lowercase letters, numbers, hyphens, dots)."
  }
}

variable "hosted_zone_id" {
  description = "The Route53 hosted zone ID in which DNS records will be created."
  type        = string

  validation {
    condition     = can(regex("^Z[A-Z0-9]{1,32}$", var.hosted_zone_id))
    error_message = "hosted_zone_id must be a valid Route53 hosted zone ID (starts with Z)."
  }
}

variable "record_name" {
  description = "The DNS record name (relative to the hosted zone, e.g. 'api' or 'api.example.com.')."
  type        = string
}

variable "record_type" {
  description = "DNS record type. Must be 'A' or 'AAAA'."
  type        = string
  default     = "A"

  validation {
    condition     = contains(["A", "AAAA"], var.record_type)
    error_message = "record_type must be 'A' or 'AAAA'."
  }
}

variable "record_ttl" {
  description = "TTL in seconds for the DNS records. Lower values allow faster failover detection by clients."
  type        = number
  default     = 60

  validation {
    condition     = var.record_ttl >= 1 && var.record_ttl <= 3600
    error_message = "record_ttl must be between 1 and 3600 seconds."
  }
}

variable "enable_ipv6" {
  description = "When true, create both A and AAAA records for dual-stack support. primary_endpoint and secondary_endpoint must both have valid IPv6 addresses set as alternate addresses, or fqdn must be used."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Endpoint configuration
# ---------------------------------------------------------------------------

variable "primary_endpoint" {
  description = "Configuration for the primary (active) endpoint."
  type = object({
    address       = string # IP address or hostname for the health check source IP
    type          = string # HTTP | HTTPS | HTTPS_STR_MATCH | HTTP_STR_MATCH | TCP
    port          = number # TCP port (80, 443, etc.)
    path          = optional(string, "/health")
    search_string = optional(string, null) # required when type contains STR_MATCH
    fqdn          = optional(string, null) # when set, Route53 uses FQDN and sends SNI; address is still used as the record value
  })

  validation {
    condition     = contains(["HTTP", "HTTPS", "HTTPS_STR_MATCH", "HTTP_STR_MATCH", "TCP"], var.primary_endpoint.type)
    error_message = "primary_endpoint.type must be one of: HTTP, HTTPS, HTTPS_STR_MATCH, HTTP_STR_MATCH, TCP."
  }

  validation {
    condition     = var.primary_endpoint.port >= 1 && var.primary_endpoint.port <= 65535
    error_message = "primary_endpoint.port must be between 1 and 65535."
  }

  validation {
    condition = (
      !can(regex("STR_MATCH", var.primary_endpoint.type)) ||
      (var.primary_endpoint.search_string != null && length(var.primary_endpoint.search_string) > 0)
    )
    error_message = "primary_endpoint.search_string is required when type is HTTPS_STR_MATCH or HTTP_STR_MATCH."
  }
}

variable "primary_ipv6_address" {
  description = "IPv6 address for the primary endpoint. Required when enable_ipv6 = true and using A/AAAA records."
  type        = string
  default     = null
}

variable "secondary_endpoint" {
  description = "Configuration for the secondary (passive failover) endpoint."
  type = object({
    address       = string
    type          = string
    port          = number
    path          = optional(string, "/health")
    search_string = optional(string, null)
    fqdn          = optional(string, null)
  })

  validation {
    condition     = contains(["HTTP", "HTTPS", "HTTPS_STR_MATCH", "HTTP_STR_MATCH", "TCP"], var.secondary_endpoint.type)
    error_message = "secondary_endpoint.type must be one of: HTTP, HTTPS, HTTPS_STR_MATCH, HTTP_STR_MATCH, TCP."
  }

  validation {
    condition     = var.secondary_endpoint.port >= 1 && var.secondary_endpoint.port <= 65535
    error_message = "secondary_endpoint.port must be between 1 and 65535."
  }

  validation {
    condition = (
      !can(regex("STR_MATCH", var.secondary_endpoint.type)) ||
      (var.secondary_endpoint.search_string != null && length(var.secondary_endpoint.search_string) > 0)
    )
    error_message = "secondary_endpoint.search_string is required when type is HTTPS_STR_MATCH or HTTP_STR_MATCH."
  }
}

variable "secondary_ipv6_address" {
  description = "IPv6 address for the secondary endpoint. Required when enable_ipv6 = true."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Health check configuration
# ---------------------------------------------------------------------------

variable "health_check_regions" {
  description = "List of AWS regions from which Route53 performs health checks. Must be 1, 3, or a valid set of up to 8 regions. Route53 reports healthy if a majority of regions succeed."
  type        = list(string)
  default     = ["us-east-1", "eu-west-1", "ap-northeast-1"]

  validation {
    condition     = length(var.health_check_regions) >= 1 && length(var.health_check_regions) <= 8
    error_message = "health_check_regions must contain between 1 and 8 regions."
  }
}

variable "failure_threshold" {
  description = "Number of consecutive health check failures required before Route53 considers the endpoint unhealthy."
  type        = number
  default     = 3

  validation {
    condition     = var.failure_threshold >= 1 && var.failure_threshold <= 10
    error_message = "failure_threshold must be between 1 and 10."
  }
}

variable "request_interval" {
  description = "Health check request interval in seconds. Must be 10 (fast) or 30 (standard). Fast checks incur additional cost."
  type        = number
  default     = 30

  validation {
    condition     = contains([10, 30], var.request_interval)
    error_message = "request_interval must be 10 or 30."
  }
}

variable "measure_latency" {
  description = "When true, Route53 measures and reports latency for the health check. Cannot be changed after creation."
  type        = bool
  default     = false
}

variable "enable_calculated_health_check" {
  description = "When true, creates a calculated health check that aggregates both primary and secondary health checks. Useful for composite monitoring dashboards."
  type        = bool
  default     = false
}

variable "calculated_health_check_threshold" {
  description = "Number of child health checks that must be healthy for the calculated health check to report healthy. Defaults to 1 (either region up = healthy)."
  type        = number
  default     = 1

  validation {
    condition     = var.calculated_health_check_threshold >= 1
    error_message = "calculated_health_check_threshold must be at least 1."
  }
}

# ---------------------------------------------------------------------------
# Alarm and notification configuration
# ---------------------------------------------------------------------------

variable "enable_alarms" {
  description = "When true, creates CloudWatch alarms and an SNS topic for health check state change notifications."
  type        = bool
  default     = true
}

variable "alarm_emails" {
  description = "List of email addresses to subscribe to the SNS topic for health check failure alerts."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for email in var.alarm_emails : can(regex("^[^@]+@[^@]+\\.[^@]+$", email))
    ])
    error_message = "All alarm_emails must be valid email addresses."
  }
}

variable "alarm_evaluation_periods" {
  description = "Number of evaluation periods before the CloudWatch alarm transitions state."
  type        = number
  default     = 2

  validation {
    condition     = var.alarm_evaluation_periods >= 1
    error_message = "alarm_evaluation_periods must be at least 1."
  }
}

variable "enable_composite_alarm" {
  description = "When true, creates a composite CloudWatch alarm that fires only when BOTH primary and secondary endpoints are unhealthy (total outage escalation)."
  type        = bool
  default     = false
}

variable "enable_eventbridge_rule" {
  description = "When true, creates an EventBridge rule that captures Route53 health check state change events and forwards them to the SNS topic."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Tagging
# ---------------------------------------------------------------------------

variable "tags" {
  description = "Map of tags applied to all resources created by this module."
  type        = map(string)
  default     = {}
}
