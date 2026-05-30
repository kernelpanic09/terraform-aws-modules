##############################################################################
# aws-backup Terraform module
#
# Providers expected from the caller:
#   aws         - default provider (primary region)
#   aws.replica - provider alias in replica_region (required when
#                 enable_cross_region_copy = true)
##############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  # Merge caller-supplied tags with mandatory module-level tags.
  common_tags = merge(var.tags, {
    ManagedBy = "terraform"
    Module    = "aws-backup"
  })

  # Flatten backup plans + rules for use in for_each maps.
  # Key format: "<plan_name>/<rule_name>"
  all_rules = merge([
    for plan in var.backup_plans : {
      for rule in plan.rules :
      "${plan.name}/${rule.name}" => merge(rule, { plan_name = plan.name })
    }
  ]...)

}

# ------------------------------------------------------------------------------
# KMS key. primary vault encryption
# ------------------------------------------------------------------------------

resource "aws_kms_key" "backup" {
  description             = "KMS key for AWS Backup vault: ${var.name}"
  deletion_window_in_days = var.kms_deletion_window
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${local.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowBackupServiceEncryptDecrypt"
        Effect = "Allow"
        Principal = {
          Service = "backup.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowSNSEncryptDecrypt"
        Effect = "Allow"
        Principal = {
          Service = "sns.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
        ]
        Resource = "*"
      },
    ]
  })

  tags = local.common_tags
}

resource "aws_kms_alias" "backup" {
  name          = "alias/${var.name}-backup"
  target_key_id = aws_kms_key.backup.key_id
}

# ------------------------------------------------------------------------------
# KMS key. replica vault encryption (created in replica region)
# ------------------------------------------------------------------------------

resource "aws_kms_key" "replica" {
  count = var.enable_cross_region_copy ? 1 : 0

  provider = aws.replica

  description             = "KMS key for AWS Backup replica vault: ${var.name} in ${var.replica_region}"
  deletion_window_in_days = var.kms_deletion_window
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${local.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowBackupServiceEncryptDecrypt"
        Effect = "Allow"
        Principal = {
          Service = "backup.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
    ]
  })

  tags = local.common_tags
}

resource "aws_kms_alias" "replica" {
  count = var.enable_cross_region_copy ? 1 : 0

  provider = aws.replica

  name          = "alias/${var.name}-backup-replica"
  target_key_id = aws_kms_key.replica[0].key_id
}

# ------------------------------------------------------------------------------
# Primary backup vault
# ------------------------------------------------------------------------------

resource "aws_backup_vault" "primary" {
  name        = "${var.name}-primary"
  kms_key_arn = aws_kms_key.backup.arn

  tags = local.common_tags
}

# ------------------------------------------------------------------------------
# Vault lock. primary vault
# ------------------------------------------------------------------------------

resource "aws_backup_vault_lock_configuration" "primary" {
  count = var.enable_vault_lock ? 1 : 0

  backup_vault_name   = aws_backup_vault.primary.name
  changeable_for_days = var.vault_lock_changeable_for_days
  max_retention_days  = var.vault_lock_max_retention_days
  min_retention_days  = var.vault_lock_min_retention_days

  # NOTE: vault_lock_mode is applied via vault policy (see below). AWS Backup's
  # vault lock resource applies the retention window; mode is enforced through
  # the vault access policy.
}

# Vault access policy that enforces the lock mode.
# GOVERNANCE: only privileged IAM users (with backup:DeleteRecoveryPoint + vault lock
#             bypass) can remove recovery points.
# COMPLIANCE: no principal, including root, can delete recovery points or the vault.
resource "aws_backup_vault_policy" "lock_mode" {
  count = var.enable_vault_lock ? 1 : 0

  backup_vault_name = aws_backup_vault.primary.name

  policy = var.vault_lock_mode == "COMPLIANCE" ? jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyDeleteRecoveryPointCompliance"
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action = [
          "backup:DeleteRecoveryPoint",
          "backup:UpdateRecoveryPointLifecycle",
          "backup:PutBackupVaultAccessPolicy",
          "backup:DeleteBackupVault",
        ]
        Resource = aws_backup_vault.primary.arn
      },
    ]
    }) : jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyDeleteRecoveryPointGovernance"
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action = [
          "backup:DeleteRecoveryPoint",
          "backup:UpdateRecoveryPointLifecycle",
        ]
        Resource = aws_backup_vault.primary.arn
        Condition = {
          StringNotLike = {
            "aws:PrincipalArn" = [
              "arn:aws:iam::${local.account_id}:role/aws-reserved/sso.amazonaws.com/*",
              "arn:aws:iam::${local.account_id}:root",
            ]
          }
        }
      },
    ]
  })
}

# ------------------------------------------------------------------------------
# Replica vault (created in replica region via aws.replica provider)
# ------------------------------------------------------------------------------

resource "aws_backup_vault" "replica" {
  count = var.enable_cross_region_copy ? 1 : 0

  provider = aws.replica

  name        = "${var.name}-replica"
  kms_key_arn = aws_kms_key.replica[0].arn

  tags = local.common_tags
}

# ------------------------------------------------------------------------------
# IAM role for AWS Backup service
# ------------------------------------------------------------------------------

data "aws_iam_policy_document" "backup_assume_role" {
  statement {
    sid     = "AllowBackupServiceAssumeRole"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "${var.name}-backup-role"
  assume_role_policy = data.aws_iam_policy_document.backup_assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "backup_service" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "restore_service" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

# Allow the role to use the vault KMS key for cross-account / cross-region copies.
resource "aws_iam_role_policy" "backup_kms" {
  name = "${var.name}-backup-kms"
  role = aws_iam_role.backup.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowKMSForBackup"
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:CreateGrant",
          "kms:RetireGrant",
        ]
        Resource = compact([
          aws_kms_key.backup.arn,
          var.enable_cross_region_copy ? aws_kms_key.replica[0].arn : "",
        ])
      },
    ]
  })
}

# Allow the role to pass itself (needed for some resource types).
resource "aws_iam_role_policy" "backup_pass_role" {
  name = "${var.name}-backup-pass-role"
  role = aws_iam_role.backup.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowPassRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.backup.arn
      },
    ]
  })
}

# ------------------------------------------------------------------------------
# SNS topic for backup notifications
# ------------------------------------------------------------------------------

resource "aws_sns_topic" "backup" {
  name              = "${var.name}-backup-notifications"
  kms_master_key_id = aws_kms_key.backup.id

  tags = local.common_tags
}

resource "aws_sns_topic_policy" "backup" {
  arn = aws_sns_topic.backup.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowBackupPublish"
        Effect = "Allow"
        Principal = {
          Service = "backup.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.backup.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        }
      },
    ]
  })
}

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.notification_emails)

  topic_arn = aws_sns_topic.backup.arn
  protocol  = "email"
  endpoint  = each.value
}

# ------------------------------------------------------------------------------
# Vault notifications -> SNS
# ------------------------------------------------------------------------------

resource "aws_backup_vault_notifications" "primary" {
  backup_vault_name   = aws_backup_vault.primary.name
  sns_topic_arn       = aws_sns_topic.backup.arn
  backup_vault_events = var.notification_events
}

# ------------------------------------------------------------------------------
# Backup plans
# ------------------------------------------------------------------------------

resource "aws_backup_plan" "this" {
  for_each = { for plan in var.backup_plans : plan.name => plan }

  name = "${var.name}-${each.key}"

  dynamic "rule" {
    for_each = each.value.rules

    content {
      rule_name                = rule.value.name
      target_vault_name        = aws_backup_vault.primary.name
      schedule                 = rule.value.schedule
      start_window             = rule.value.start_window_minutes
      completion_window        = rule.value.completion_window_minutes
      enable_continuous_backup = rule.value.enable_continuous_backup

      lifecycle {
        cold_storage_after = rule.value.cold_storage_after_days
        delete_after       = rule.value.delete_after_days
      }

      # Cross-region copy action. only emitted when the rule opts in and
      # cross-region copy is globally enabled.
      dynamic "copy_action" {
        for_each = (
          var.enable_cross_region_copy && rule.value.copy_to_replica
          ? [rule.value]
          : []
        )

        content {
          destination_vault_arn = aws_backup_vault.replica[0].arn

          lifecycle {
            cold_storage_after = copy_action.value.replica_cold_storage_after_days
            delete_after       = copy_action.value.replica_delete_after_days
          }
        }
      }
    }
  }

  tags = local.common_tags

  depends_on = [aws_backup_vault.primary]
}

# ------------------------------------------------------------------------------
# Backup selections
# A single selection resource is created per plan, covering both tag-based and
# explicit-ARN-based resources. If the caller supplies neither, no selection is
# created (the plan exists but selects nothing. valid for manual assignments).
# ------------------------------------------------------------------------------

locals {
  plans_needing_selection = {
    for plan in var.backup_plans : plan.name => plan
    if length(var.selection_tags) > 0 || length(var.selection_resources) > 0
  }
}

resource "aws_backup_selection" "this" {
  for_each = local.plans_needing_selection

  name         = "${var.name}-${each.key}-selection"
  plan_id      = aws_backup_plan.this[each.key].id
  iam_role_arn = aws_iam_role.backup.arn

  # Explicit ARN list (may include wildcards).
  resources = length(var.selection_resources) > 0 ? var.selection_resources : null

  # Tag-based conditions. all tags must match (AND logic).
  dynamic "selection_tag" {
    for_each = var.selection_tags

    content {
      type  = "STRINGEQUALS"
      key   = selection_tag.value.key
      value = selection_tag.value.value
    }
  }
}

# ------------------------------------------------------------------------------
# Restore testing plan (AWS Backup Restore Testing. GA 2024)
# ------------------------------------------------------------------------------

resource "aws_backup_restore_testing_plan" "this" {
  count = var.enable_restore_testing ? 1 : 0

  name                         = "${var.name}-restore-test"
  schedule_expression          = var.restore_testing_schedule
  schedule_expression_timezone = "UTC"
  start_window_hours           = var.restore_testing_start_window_hours
  recovery_point_selection {
    algorithm             = "LATEST_WITHIN_WINDOW"
    include_vaults        = [aws_backup_vault.primary.arn]
    recovery_point_types  = ["CONTINUOUS", "SNAPSHOT"]
    selection_window_days = 1
  }

  tags = local.common_tags
}

resource "aws_backup_restore_testing_selection" "this" {
  count = var.enable_restore_testing ? 1 : 0

  name                      = "${var.name}-restore-test-selection"
  restore_testing_plan_name = aws_backup_restore_testing_plan.this[0].name
  protected_resource_type   = "EC2"
  iam_role_arn              = aws_iam_role.backup.arn

  # Tag-based filter; falls back to no filter (all resources) when empty.
  dynamic "protected_resource_conditions" {
    for_each = length(var.restore_test_selection_tags) > 0 ? [1] : []

    content {
      dynamic "string_equals" {
        for_each = var.restore_test_selection_tags

        content {
          key   = string_equals.value.key
          value = string_equals.value.value
        }
      }
    }
  }

  restore_metadata_overrides = {}
}
