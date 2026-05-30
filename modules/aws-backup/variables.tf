# ------------------------------------------------------------------------------
# Core naming and tagging
# ------------------------------------------------------------------------------

variable "name" {
  description = "Base name used as a prefix for all resources created by this module."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]{1,50}$", var.name))
    error_message = "name must be 1-50 characters and contain only letters, numbers, hyphens, and underscores."
  }
}

variable "tags" {
  description = "Map of tags applied to every resource created by this module."
  type        = map(string)
  default     = {}
}

# ------------------------------------------------------------------------------
# KMS
# ------------------------------------------------------------------------------

variable "kms_deletion_window" {
  description = "Number of days to wait before deleting the KMS key (7-30)."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_deletion_window >= 7 && var.kms_deletion_window <= 30
    error_message = "kms_deletion_window must be between 7 and 30 days."
  }
}

# ------------------------------------------------------------------------------
# Cross-region copy (replica)
# ------------------------------------------------------------------------------

variable "enable_cross_region_copy" {
  description = "When true, a secondary backup vault is created in replica_region and applicable backup rules copy recovery points there."
  type        = bool
  default     = false
}

variable "replica_region" {
  description = "AWS region for the replica vault. Required when enable_cross_region_copy is true. Must match the region configured on the aws.replica provider alias."
  type        = string
  default     = ""

  validation {
    condition     = var.replica_region == "" || can(regex("^[a-z]{2}-[a-z]+-[0-9]+$", var.replica_region))
    error_message = "replica_region must be a valid AWS region name (e.g. us-east-1) or empty string."
  }
}

# ------------------------------------------------------------------------------
# Vault lock
# ------------------------------------------------------------------------------

variable "enable_vault_lock" {
  description = "When true, a vault lock policy is applied to the primary vault for immutability."
  type        = bool
  default     = false
}

variable "vault_lock_mode" {
  description = <<-EOT
    Lock mode for the primary vault. Allowed values:
      GOVERNANCE - Privileged IAM users can remove the lock or delete recovery points.
      COMPLIANCE - The lock CANNOT be removed after the cool-off period expires.
                   Enabling COMPLIANCE mode on a production vault is IRREVERSIBLE.
                   Review the README before using this mode.
  EOT
  type        = string
  default     = "GOVERNANCE"

  validation {
    condition     = contains(["GOVERNANCE", "COMPLIANCE"], var.vault_lock_mode)
    error_message = "vault_lock_mode must be GOVERNANCE or COMPLIANCE."
  }
}

variable "vault_lock_min_retention_days" {
  description = "Minimum retention period (days) enforced by the vault lock. Must be >= 1."
  type        = number
  default     = 7

  validation {
    condition     = var.vault_lock_min_retention_days >= 1
    error_message = "vault_lock_min_retention_days must be at least 1."
  }
}

variable "vault_lock_max_retention_days" {
  description = "Maximum retention period (days) enforced by the vault lock. Must be >= vault_lock_min_retention_days."
  type        = number
  default     = 365
}

variable "vault_lock_changeable_for_days" {
  description = <<-EOT
    Number of days the vault lock remains in a changeable state before it becomes locked.
    After this window closes, a COMPLIANCE vault lock cannot be removed.
    Minimum 3 days. Set to null to lock immediately (not recommended for COMPLIANCE mode).
  EOT
  type        = number
  default     = 3

  validation {
    condition     = var.vault_lock_changeable_for_days == null ? true : var.vault_lock_changeable_for_days >= 3
    error_message = "vault_lock_changeable_for_days must be null or at least 3."
  }
}

# ------------------------------------------------------------------------------
# Backup plans
# ------------------------------------------------------------------------------

variable "backup_plans" {
  description = <<-EOT
    List of backup plans to create. Each plan contains one or more rules.
    See the module README for full field documentation and examples.
  EOT
  type = list(object({
    name = string
    rules = list(object({
      name                            = string
      schedule                        = string # AWS cron expression, e.g. "cron(0 5 * * ? *)"
      start_window_minutes            = number
      completion_window_minutes       = number
      cold_storage_after_days         = optional(number, null)
      delete_after_days               = number
      enable_continuous_backup        = optional(bool, false)
      copy_to_replica                 = optional(bool, false)
      replica_cold_storage_after_days = optional(number, null)
      replica_delete_after_days       = optional(number, null)
    }))
  }))

  validation {
    condition = alltrue([
      for plan in var.backup_plans : length(plan.rules) > 0
    ])
    error_message = "Every backup plan must have at least one rule."
  }

  validation {
    condition = alltrue(flatten([
      for plan in var.backup_plans : [
        for rule in plan.rules : rule.delete_after_days >= 1
      ]
    ]))
    error_message = "Every rule must have delete_after_days >= 1."
  }

  validation {
    condition = alltrue(flatten([
      for plan in var.backup_plans : [
        for rule in plan.rules :
        rule.cold_storage_after_days == null ? true :
        rule.cold_storage_after_days < rule.delete_after_days
      ]
    ]))
    error_message = "cold_storage_after_days must be less than delete_after_days when both are set."
  }
}

# ------------------------------------------------------------------------------
# Backup selections
# ------------------------------------------------------------------------------

variable "selection_tags" {
  description = <<-EOT
    List of resource tags used for tag-based backup selection.
    Resources that match ALL provided tags are included in every backup plan.
    Example: [{ key = "backup", value = "true" }]
  EOT
  type = list(object({
    key   = string
    value = string
  }))
  default = []
}

variable "selection_resources" {
  description = "List of specific resource ARNs to include in every backup plan. Wildcards are supported."
  type        = list(string)
  default     = []
}

# ------------------------------------------------------------------------------
# Notifications
# ------------------------------------------------------------------------------

variable "notification_emails" {
  description = "List of email addresses subscribed to the backup SNS topic. Each address receives a confirmation email that must be accepted."
  type        = list(string)
  default     = []
}

variable "notification_events" {
  description = "List of AWS Backup event types that trigger SNS notifications."
  type        = list(string)
  default = [
    "BACKUP_JOB_STARTED",
    "BACKUP_JOB_COMPLETED",
    "BACKUP_JOB_FAILED",
    "COPY_JOB_STARTED",
    "COPY_JOB_SUCCESSFUL",
    "COPY_JOB_FAILED",
    "RESTORE_JOB_COMPLETED",
    "RESTORE_JOB_FAILED",
  ]
}

# ------------------------------------------------------------------------------
# Restore testing (AWS Backup Restore Testing Plans - GA 2024)
# ------------------------------------------------------------------------------

variable "enable_restore_testing" {
  description = "When true, an AWS Backup restore testing plan is created to periodically validate restores."
  type        = bool
  default     = false
}

variable "restore_testing_schedule" {
  description = "Cron expression controlling how often restore tests run. Evaluated daily at the specified time."
  type        = string
  default     = "cron(0 8 ? * 1 *)" # Weekly, Sunday 08:00 UTC
}

variable "restore_testing_start_window_hours" {
  description = "Number of hours after the scheduled time in which the restore test job must start. Valid range: 1-168."
  type        = number
  default     = 4

  validation {
    condition     = var.restore_testing_start_window_hours >= 1 && var.restore_testing_start_window_hours <= 168
    error_message = "restore_testing_start_window_hours must be between 1 and 168."
  }
}

variable "restore_test_selection_tags" {
  description = "Tags used to select recovery points for restore testing. Follows the same format as selection_tags."
  type = list(object({
    key   = string
    value = string
  }))
  default = []
}
