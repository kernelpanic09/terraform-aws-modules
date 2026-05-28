# ------------------------------------------------------------------------------
# Primary vault
# ------------------------------------------------------------------------------

output "primary_vault_id" {
  description = "The name (ID) of the primary backup vault."
  value       = aws_backup_vault.primary.id
}

output "primary_vault_arn" {
  description = "The ARN of the primary backup vault."
  value       = aws_backup_vault.primary.arn
}

output "primary_vault_recovery_points" {
  description = "The current number of recovery points stored in the primary vault."
  value       = aws_backup_vault.primary.recovery_points
}

# ------------------------------------------------------------------------------
# Replica vault
# ------------------------------------------------------------------------------

output "replica_vault_id" {
  description = "The name (ID) of the replica backup vault. Empty string when cross-region copy is disabled."
  value       = var.enable_cross_region_copy ? aws_backup_vault.replica[0].id : ""
}

output "replica_vault_arn" {
  description = "The ARN of the replica backup vault. Empty string when cross-region copy is disabled."
  value       = var.enable_cross_region_copy ? aws_backup_vault.replica[0].arn : ""
}

# ------------------------------------------------------------------------------
# KMS keys
# ------------------------------------------------------------------------------

output "kms_key_id" {
  description = "The ID of the KMS key used to encrypt the primary backup vault."
  value       = aws_kms_key.backup.key_id
}

output "kms_key_arn" {
  description = "The ARN of the KMS key used to encrypt the primary backup vault."
  value       = aws_kms_key.backup.arn
}

output "replica_kms_key_arn" {
  description = "The ARN of the KMS key used to encrypt the replica vault. Empty string when cross-region copy is disabled."
  value       = var.enable_cross_region_copy ? aws_kms_key.replica[0].arn : ""
}

# ------------------------------------------------------------------------------
# IAM
# ------------------------------------------------------------------------------

output "backup_role_arn" {
  description = "The ARN of the IAM role used by AWS Backup."
  value       = aws_iam_role.backup.arn
}

output "backup_role_name" {
  description = "The name of the IAM role used by AWS Backup."
  value       = aws_iam_role.backup.name
}

# ------------------------------------------------------------------------------
# SNS
# ------------------------------------------------------------------------------

output "sns_topic_arn" {
  description = "The ARN of the SNS topic that receives backup event notifications."
  value       = aws_sns_topic.backup.arn
}

output "sns_topic_name" {
  description = "The name of the SNS topic that receives backup event notifications."
  value       = aws_sns_topic.backup.name
}

# ------------------------------------------------------------------------------
# Backup plans
# ------------------------------------------------------------------------------

output "backup_plan_ids" {
  description = "Map of plan name to backup plan ID."
  value       = { for k, v in aws_backup_plan.this : k => v.id }
}

output "backup_plan_arns" {
  description = "Map of plan name to backup plan ARN."
  value       = { for k, v in aws_backup_plan.this : k => v.arn }
}

output "backup_plan_versions" {
  description = "Map of plan name to the most recent plan version ID."
  value       = { for k, v in aws_backup_plan.this : k => v.version }
}

# ------------------------------------------------------------------------------
# Restore testing
# ------------------------------------------------------------------------------

output "restore_testing_plan_name" {
  description = "The name of the restore testing plan. Empty string when restore testing is disabled."
  value       = var.enable_restore_testing ? aws_backup_restore_testing_plan.this[0].name : ""
}
