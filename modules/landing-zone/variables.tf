###############################################################################
# General
###############################################################################

variable "name" {
  description = "Base name used for all resource names (e.g., 'myorg'). The S3 state bucket will be named '{name}-terraform-state-{account_id}' and the DynamoDB table '{name}-terraform-locks'."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$", var.name))
    error_message = "name must be 3-40 lowercase alphanumeric characters or hyphens, and must start and end with alphanumeric."
  }
}

variable "tags" {
  description = "Map of tags applied to all resources created by this module."
  type        = map(string)
  default     = {}
}

###############################################################################
# Terraform state backend (S3 + DynamoDB)
###############################################################################

variable "enable_state_backend" {
  description = "Whether to create the S3 bucket and DynamoDB table for Terraform remote state."
  type        = bool
  default     = true
}

variable "state_bucket_force_destroy" {
  description = "Allow Terraform to destroy the state bucket even if it contains objects. Useful for ephemeral environments; keep false in production."
  type        = bool
  default     = false
}

variable "state_bucket_versioning_enabled" {
  description = "Enable S3 versioning on the Terraform state bucket."
  type        = bool
  default     = true
}

variable "state_bucket_lifecycle_noncurrent_days" {
  description = "Number of days to retain non-current object versions in the state bucket before expiring them."
  type        = number
  default     = 90

  validation {
    condition     = var.state_bucket_lifecycle_noncurrent_days >= 1
    error_message = "state_bucket_lifecycle_noncurrent_days must be at least 1."
  }
}

variable "dynamodb_billing_mode" {
  description = "DynamoDB billing mode for the lock table. PAY_PER_REQUEST is recommended for low-frequency locking."
  type        = string
  default     = "PAY_PER_REQUEST"

  validation {
    condition     = contains(["PAY_PER_REQUEST", "PROVISIONED"], var.dynamodb_billing_mode)
    error_message = "dynamodb_billing_mode must be PAY_PER_REQUEST or PROVISIONED."
  }
}

variable "dynamodb_read_capacity" {
  description = "Read capacity units for the DynamoDB lock table. Only used when dynamodb_billing_mode is PROVISIONED."
  type        = number
  default     = 5
}

variable "dynamodb_write_capacity" {
  description = "Write capacity units for the DynamoDB lock table. Only used when dynamodb_billing_mode is PROVISIONED."
  type        = number
  default     = 5
}

###############################################################################
# AWS Organizations
###############################################################################

variable "enable_organizations" {
  description = "Whether to manage the AWS Organization. Set to true only when running from the management account. The organization must not already exist, or it will be imported."
  type        = bool
  default     = false
}

variable "organizations_aws_service_access_principals" {
  description = "List of AWS service principal names to enable trusted access for within the organization."
  type        = list(string)
  default = [
    "cloudtrail.amazonaws.com",
    "config.amazonaws.com",
    "sso.amazonaws.com",
  ]
}

variable "organizations_enabled_policy_types" {
  description = "List of policy types to enable on the organization root. Include SERVICE_CONTROL_POLICY to use SCPs."
  type        = list(string)
  default     = ["SERVICE_CONTROL_POLICY"]
}

variable "enable_scp_deny_leave_org" {
  description = "Whether to create and attach an SCP that prevents member accounts from leaving the organization."
  type        = bool
  default     = true
}

###############################################################################
# CloudTrail
###############################################################################

variable "enable_cloudtrail" {
  description = "Whether to create a CloudTrail trail logging management and data events."
  type        = bool
  default     = true
}

variable "cloudtrail_name" {
  description = "Name of the CloudTrail trail. Defaults to '{name}-cloudtrail'."
  type        = string
  default     = ""
}

variable "cloudtrail_is_organization_trail" {
  description = "Whether the CloudTrail trail covers all accounts in the organization. Requires enable_organizations = true in the management account."
  type        = bool
  default     = false
}

variable "cloudtrail_include_global_service_events" {
  description = "Include global service events (e.g., IAM API calls) in the trail."
  type        = bool
  default     = true
}

variable "cloudtrail_enable_log_file_validation" {
  description = "Enable CloudTrail log file integrity validation."
  type        = bool
  default     = true
}

variable "cloudtrail_log_retention_days" {
  description = "Number of days to retain CloudWatch Logs for CloudTrail. Set to 0 to disable CloudWatch Logs delivery."
  type        = number
  default     = 365

  validation {
    condition     = contains([0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.cloudtrail_log_retention_days)
    error_message = "cloudtrail_log_retention_days must be a value accepted by CloudWatch Logs (0 to disable, or a supported retention value)."
  }
}

variable "cloudtrail_s3_key_prefix" {
  description = "S3 key prefix for CloudTrail log delivery."
  type        = string
  default     = "cloudtrail"
}

###############################################################################
# AWS Config
###############################################################################

variable "enable_config" {
  description = "Whether to create an AWS Config recorder and delivery channel."
  type        = bool
  default     = false
}

variable "config_delivery_frequency" {
  description = "How frequently AWS Config delivers configuration snapshots."
  type        = string
  default     = "TwentyFour_Hours"

  validation {
    condition = contains([
      "One_Hour", "Three_Hours", "Six_Hours", "Twelve_Hours", "TwentyFour_Hours"
    ], var.config_delivery_frequency)
    error_message = "config_delivery_frequency must be one of: One_Hour, Three_Hours, Six_Hours, Twelve_Hours, TwentyFour_Hours."
  }
}

variable "config_include_global_resource_types" {
  description = "Include global resource types (e.g., IAM) in the Config recording scope."
  type        = bool
  default     = true
}

###############################################################################
# Budget alarms
###############################################################################

variable "enable_budget_alarm" {
  description = "Whether to create a monthly budget alert."
  type        = bool
  default     = true
}

variable "budget_limit_amount" {
  description = "Monthly budget limit in USD."
  type        = number
  default     = 100

  validation {
    condition     = var.budget_limit_amount > 0
    error_message = "budget_limit_amount must be greater than 0."
  }
}

variable "budget_alert_threshold_percent" {
  description = "Percentage of the budget at which the alert triggers (e.g., 80 means alert at 80% of limit)."
  type        = number
  default     = 80

  validation {
    condition     = var.budget_alert_threshold_percent > 0 && var.budget_alert_threshold_percent <= 1000
    error_message = "budget_alert_threshold_percent must be between 1 and 1000."
  }
}

variable "budget_alert_email_addresses" {
  description = "List of email addresses to notify when the budget threshold is breached. An SNS subscription is created for each address."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for e in var.budget_alert_email_addresses : can(regex("^[^@]+@[^@]+\\.[^@]+$", e))])
    error_message = "Each entry in budget_alert_email_addresses must be a valid email address."
  }
}

variable "budget_time_unit" {
  description = "Time unit for the budget period."
  type        = string
  default     = "MONTHLY"

  validation {
    condition     = contains(["DAILY", "MONTHLY", "QUARTERLY", "ANNUALLY"], var.budget_time_unit)
    error_message = "budget_time_unit must be DAILY, MONTHLY, QUARTERLY, or ANNUALLY."
  }
}
