# ---------------------------------------------------------------------------
# Core identity
# ---------------------------------------------------------------------------

variable "name" {
  description = "Prefix used for all resource names and tags."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Engine
# ---------------------------------------------------------------------------

variable "engine" {
  description = "Aurora engine family. Must be 'aurora-postgresql' or 'aurora-mysql'."
  type        = string
  default     = "aurora-postgresql"

  validation {
    condition     = contains(["aurora-postgresql", "aurora-mysql"], var.engine)
    error_message = "engine must be 'aurora-postgresql' or 'aurora-mysql'."
  }
}

variable "engine_version" {
  description = "Aurora engine version string, e.g. '15.4' for PostgreSQL or '8.0.mysql_aurora.3.04.0' for MySQL."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]", var.engine_version))
    error_message = "engine_version must start with a numeric major.minor version, e.g. '15.4' or '8.0.mysql_aurora.3.04.0'."
  }
}

# ---------------------------------------------------------------------------
# Instances
# ---------------------------------------------------------------------------

variable "instance_class" {
  description = "DB instance class for all cluster instances, e.g. 'db.r6g.large'."
  type        = string
  default     = "db.r6g.large"

  validation {
    condition     = can(regex("^db\\.[a-z0-9]+\\.[a-z0-9]+$", var.instance_class))
    error_message = "instance_class must match the pattern db.<family>.<size>, e.g. db.r6g.large."
  }
}

variable "instance_count" {
  description = "Total number of DB instances (writer + readers). Minimum 1."
  type        = number
  default     = 2

  validation {
    condition     = var.instance_count >= 1
    error_message = "instance_count must be at least 1 (the writer)."
  }
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

variable "vpc_id" {
  description = "VPC ID where the cluster and security group will be created."
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for the DB subnet group. Needs at least 2 AZs."
  type        = list(string)
}

variable "allowed_security_group_ids" {
  description = "Security group IDs permitted to reach the cluster port."
  type        = list(string)
  default     = []
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks permitted to reach the cluster port."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

variable "database_name" {
  description = "Name of the initial database created in the cluster."
  type        = string
}

variable "master_username" {
  description = "Master DB username."
  type        = string
  default     = "dbadmin"
}

variable "master_password" {
  description = "Master DB password. Leave empty to generate one via Secrets Manager."
  type        = string
  default     = ""
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Auth and access
# ---------------------------------------------------------------------------

variable "enable_iam_auth" {
  description = "Enable IAM database authentication."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Encryption
# ---------------------------------------------------------------------------

variable "kms_key_id" {
  description = "KMS key ARN for at-rest encryption of the cluster and Performance Insights. Uses the default RDS key if empty."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------

variable "backup_retention_days" {
  description = "Days to retain automated backups. Must be between 1 and 35."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be between 1 and 35."
  }
}

variable "preferred_backup_window" {
  description = "Daily time range for automated backups, in UTC, e.g. '02:00-03:00'."
  type        = string
  default     = "02:00-03:00"
}

variable "preferred_maintenance_window" {
  description = "Weekly maintenance window, e.g. 'sun:05:00-sun:06:00'."
  type        = string
  default     = "sun:05:00-sun:06:00"
}

# ---------------------------------------------------------------------------
# Safety
# ---------------------------------------------------------------------------

variable "deletion_protection" {
  description = "Enable deletion protection on the cluster."
  type        = bool
  default     = true
}

variable "skip_final_snapshot" {
  description = "Skip the final cluster snapshot on destroy. Set to false in production."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Performance Insights
# ---------------------------------------------------------------------------

variable "enable_performance_insights" {
  description = "Enable Performance Insights on all instances."
  type        = bool
  default     = true
}

variable "performance_insights_retention_days" {
  description = "Retention period for Performance Insights data, in days. Must be 7 or a multiple of 31 up to 731."
  type        = number
  default     = 7

  validation {
    condition = (
      var.performance_insights_retention_days == 7 ||
      (var.performance_insights_retention_days >= 31 &&
        var.performance_insights_retention_days <= 731 &&
      var.performance_insights_retention_days % 31 == 0)
    )
    error_message = "performance_insights_retention_days must be 7 or a multiple of 31 between 31 and 731."
  }
}

# ---------------------------------------------------------------------------
# Enhanced monitoring
# ---------------------------------------------------------------------------

variable "enable_enhanced_monitoring" {
  description = "Enable Enhanced Monitoring (OS-level metrics) on all instances."
  type        = bool
  default     = true
}

variable "monitoring_interval" {
  description = "Enhanced Monitoring interval in seconds. 0 disables it. Valid values: 0, 1, 5, 10, 15, 30, 60."
  type        = number
  default     = 60

  validation {
    condition     = contains([0, 1, 5, 10, 15, 30, 60], var.monitoring_interval)
    error_message = "monitoring_interval must be one of: 0, 1, 5, 10, 15, 30, 60."
  }
}

# ---------------------------------------------------------------------------
# Parameter groups
# ---------------------------------------------------------------------------

variable "cluster_parameters" {
  description = "Additional cluster parameter group entries. Merged with module defaults. Map of name => { value, apply_method }."
  type = map(object({
    value        = string
    apply_method = string
  }))
  default = {}
}

variable "db_parameters" {
  description = "Additional DB parameter group entries for instances. Merged with module defaults."
  type = map(object({
    value        = string
    apply_method = string
  }))
  default = {}
}

# ---------------------------------------------------------------------------
# Cross-region read replica
# ---------------------------------------------------------------------------

variable "enable_cross_region_replica" {
  description = "Create a cross-region Aurora read replica using the aws.replica provider alias."
  type        = bool
  default     = false
}

variable "replica_region" {
  description = "AWS region for the cross-region read replica. Required when enable_cross_region_replica = true."
  type        = string
  default     = ""
}

variable "replica_instance_count" {
  description = "Number of instances in the cross-region replica cluster. Minimum 1."
  type        = number
  default     = 1

  validation {
    condition     = var.replica_instance_count >= 1
    error_message = "replica_instance_count must be at least 1."
  }
}

variable "replica_subnet_ids" {
  description = "Subnet IDs in the replica region for the replica subnet group. Required when enable_cross_region_replica = true."
  type        = list(string)
  default     = []
}

variable "replica_instance_class" {
  description = "Instance class for the cross-region replica. Defaults to the same class as the primary."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# CloudWatch log exports
# ---------------------------------------------------------------------------

variable "cloudwatch_logs_exports" {
  description = "Override the log types exported to CloudWatch. Module sets sensible defaults per engine if empty."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Alarms
# ---------------------------------------------------------------------------

variable "alarm_emails" {
  description = "Email addresses subscribed to the SNS alarm topic."
  type        = list(string)
  default     = []
}

variable "existing_sns_topic_arn" {
  description = "Use an existing SNS topic ARN instead of creating one. If empty, a topic is created."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Secrets Manager
# ---------------------------------------------------------------------------

variable "enable_secrets_manager" {
  description = "Store the master password in AWS Secrets Manager."
  type        = bool
  default     = true
}

variable "enable_rotation" {
  description = "Enable automatic secret rotation via Lambda. Requires enable_secrets_manager = true."
  type        = bool
  default     = false
}

variable "rotation_days" {
  description = "Number of days between automatic secret rotations."
  type        = number
  default     = 30

  validation {
    condition     = var.rotation_days >= 1 && var.rotation_days <= 365
    error_message = "rotation_days must be between 1 and 365."
  }
}
