# ------------------------------------------------------------------------------
# Core identity
# ------------------------------------------------------------------------------

variable "name" {
  description = "Name prefix applied to all resources created by this module. Must be lowercase alphanumeric with hyphens only, 1-32 characters."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.name)) && length(var.name) >= 1 && length(var.name) <= 32
    error_message = "Name must be 1-32 characters, lowercase alphanumeric and hyphens only."
  }
}

# ------------------------------------------------------------------------------
# GuardDuty data sources
# ------------------------------------------------------------------------------

variable "enable_s3_protection" {
  description = "Enable GuardDuty S3 protection to monitor S3 data plane API operations for threats such as credential exfiltration and anomalous data access."
  type        = bool
  default     = true
}

variable "enable_k8s_protection" {
  description = "Enable GuardDuty Kubernetes audit log monitoring for EKS clusters. Detects suspicious control-plane activity including privilege escalation and container escapes."
  type        = bool
  default     = false
}

variable "enable_malware_protection" {
  description = "Enable GuardDuty malware detection by scanning EBS volumes attached to EC2 instances with active findings. Incurs per-GB scan costs."
  type        = bool
  default     = false
}

variable "finding_publishing_frequency" {
  description = "How often GuardDuty publishes subsequent occurrences of an existing finding to EventBridge and S3. Initial findings are always published immediately. Valid values: FIFTEEN_MINUTES, ONE_HOUR, SIX_HOURS."
  type        = string
  default     = "FIFTEEN_MINUTES"

  validation {
    condition     = contains(["FIFTEEN_MINUTES", "ONE_HOUR", "SIX_HOURS"], var.finding_publishing_frequency)
    error_message = "finding_publishing_frequency must be one of: FIFTEEN_MINUTES, ONE_HOUR, SIX_HOURS."
  }
}

# ------------------------------------------------------------------------------
# Security Hub
# ------------------------------------------------------------------------------

variable "enable_security_hub" {
  description = "Enable AWS Security Hub and subscribe to the CIS AWS Foundations Benchmark v1.4.0 and AWS Foundational Security Best Practices standards. Security Hub aggregates findings from GuardDuty and other services into a single pane."
  type        = bool
  default     = true
}

# ------------------------------------------------------------------------------
# Auto-remediation
# ------------------------------------------------------------------------------

variable "enable_auto_remediation" {
  description = "Deploy the auto-remediation Lambda function. When enabled, the function automatically disables compromised IAM access keys, blocks public S3 access, and revokes unrestricted security group ingress rules in response to high-severity GuardDuty findings."
  type        = bool
  default     = true
}

# ------------------------------------------------------------------------------
# Alerting
# ------------------------------------------------------------------------------

variable "alert_emails" {
  description = "List of email addresses subscribed to both the high-severity and medium-severity SNS topics. Each address receives a confirmation email that must be accepted before alerts are delivered."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for email in var.alert_emails :
      can(regex("^[a-zA-Z0-9._%+\\-]+@[a-zA-Z0-9.\\-]+\\.[a-zA-Z]{2,}$", email))
    ])
    error_message = "All values in alert_emails must be valid email addresses."
  }
}

# ------------------------------------------------------------------------------
# Tags
# ------------------------------------------------------------------------------

variable "tags" {
  description = "Map of additional tags merged onto all resources. Module-managed tags (ManagedBy, Module) are always applied and cannot be overridden."
  type        = map(string)
  default     = {}
}
