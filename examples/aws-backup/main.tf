##############################################################################
# Example: aws-backup module
#
# Demonstrates:
#   - Three backup plans (daily, weekly-archive, continuous PITR)
#   - Cross-region copy to us-west-2
#   - Tag-based resource selection (backup=true)
#   - Vault lock in GOVERNANCE mode
#   - Email notifications
#   - Restore testing plan
#
# Prerequisites:
#   export AWS_PROFILE=my-profile   # or set AWS_ACCESS_KEY_ID etc.
#   terraform init
#   terraform plan
##############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40.0"
    }
  }
}

# Primary region. all main resources land here.
provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = "homelab"
      Environment = "prod"
      ManagedBy   = "terraform"
    }
  }
}

# Replica provider alias. must be present even if you later disable
# cross-region copy (Terraform resolves provider references statically).
provider "aws" {
  alias  = "replica"
  region = "us-west-2"

  default_tags {
    tags = {
      Project     = "homelab"
      Environment = "prod"
      ManagedBy   = "terraform"
    }
  }
}

# ------------------------------------------------------------------------------
# Module invocation
# ------------------------------------------------------------------------------

module "backup" {
  source = "../../modules/aws-backup"

  # Pass both providers so the module can create replica-region resources.
  providers = {
    aws         = aws
    aws.replica = aws.replica
  }

  # ---- Naming ----------------------------------------------------------------
  name = "homelab-prod"

  # ---- KMS -------------------------------------------------------------------
  kms_deletion_window = 30

  # ---- Cross-region copy -----------------------------------------------------
  enable_cross_region_copy = true
  replica_region           = "us-west-2"

  # ---- Vault lock (GOVERNANCE mode. safe to remove if needed) --------------
  enable_vault_lock              = true
  vault_lock_mode                = "GOVERNANCE"
  vault_lock_min_retention_days  = 7
  vault_lock_max_retention_days  = 365
  vault_lock_changeable_for_days = 3

  # ---- Backup plans ----------------------------------------------------------
  backup_plans = [
    # Plan 1: Daily production snapshots
    # Every day at 05:00 UTC, 35-day retention, cross-region copy.
    {
      name = "daily-prod"
      rules = [
        {
          name                      = "daily-5am-utc"
          schedule                  = "cron(0 5 * * ? *)"
          start_window_minutes      = 60
          completion_window_minutes = 180
          delete_after_days         = 35
          copy_to_replica           = true
          replica_delete_after_days = 35
        }
      ]
    },

    # Plan 2: Weekly archive with tiered storage
    # Every Sunday at 03:00 UTC.
    # Recovery points move to cold storage after 90 days and expire after 365.
    # Replica has a matching lifecycle.
    {
      name = "weekly-archive"
      rules = [
        {
          name                            = "weekly-sunday-3am-utc"
          schedule                        = "cron(0 3 ? * 1 *)"
          start_window_minutes            = 60
          completion_window_minutes       = 360
          cold_storage_after_days         = 90
          delete_after_days               = 365
          copy_to_replica                 = true
          replica_cold_storage_after_days = 90
          replica_delete_after_days       = 365
        }
      ]
    },

    # Plan 3: Continuous backup for PITR-supported resources
    # Targets RDS, DynamoDB, EFS, and other services that support
    # point-in-time recovery. The schedule still creates periodic recovery
    # points; the continuous backup runs in the background.
    # No cross-region copy on PITR backups (cross-region PITR requires
    # separate service-level configuration on each resource).
    {
      name = "continuous-pitr"
      rules = [
        {
          name                      = "continuous-daily-checkpoint"
          schedule                  = "cron(0 1 * * ? *)"
          start_window_minutes      = 60
          completion_window_minutes = 180
          delete_after_days         = 35
          enable_continuous_backup  = true
          copy_to_replica           = false
        }
      ]
    },
  ]

  # ---- Resource selection ----------------------------------------------------
  # All three plans will back up any resource tagged backup=true.
  selection_tags = [
    {
      key   = "backup"
      value = "true"
    }
  ]

  # Optionally add specific resource ARNs (uncomment and populate as needed):
  # selection_resources = [
  #   "arn:aws:dynamodb:us-east-1:123456789012:table/my-critical-table",
  # ]

  # ---- Notifications ---------------------------------------------------------
  # Each address receives a confirmation email from AWS SNS.
  # The subscription is inactive until confirmed.
  notification_emails = [
    "ops@example.com",
    "oncall@example.com",
  ]

  # Subscribe to all event types (default). Override to reduce noise:
  # notification_events = [
  #   "BACKUP_JOB_FAILED",
  #   "COPY_JOB_FAILED",
  #   "RESTORE_JOB_FAILED",
  # ]

  # ---- Restore testing -------------------------------------------------------
  enable_restore_testing = true

  # Weekly restore test: every Sunday at 08:00 UTC.
  restore_testing_schedule           = "cron(0 8 ? * 1 *)"
  restore_testing_start_window_hours = 4

  # Only restore-test recovery points from resources tagged restore-test=true.
  restore_test_selection_tags = [
    {
      key   = "restore-test"
      value = "true"
    }
  ]

  # ---- Tags ------------------------------------------------------------------
  tags = {
    Environment = "prod"
    Team        = "platform"
    CostCenter  = "infra"
  }
}

# ------------------------------------------------------------------------------
# Outputs
# ------------------------------------------------------------------------------

output "primary_vault_arn" {
  description = "ARN of the primary backup vault."
  value       = module.backup.primary_vault_arn
}

output "replica_vault_arn" {
  description = "ARN of the replica backup vault."
  value       = module.backup.replica_vault_arn
}

output "backup_plan_ids" {
  description = "Map of plan name to backup plan ID."
  value       = module.backup.backup_plan_ids
}

output "sns_topic_arn" {
  description = "ARN of the backup notifications SNS topic."
  value       = module.backup.sns_topic_arn
}

output "backup_role_arn" {
  description = "ARN of the AWS Backup IAM role."
  value       = module.backup.backup_role_arn
}

output "restore_testing_plan_name" {
  description = "Name of the restore testing plan."
  value       = module.backup.restore_testing_plan_name
}
