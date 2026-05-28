###############################################################################
# Terraform state backend
###############################################################################

output "state_bucket_id" {
  description = "Name/ID of the S3 bucket used for Terraform remote state. Empty string when enable_state_backend is false."
  value       = var.enable_state_backend ? aws_s3_bucket.state[0].id : ""
}

output "state_bucket_arn" {
  description = "ARN of the Terraform state S3 bucket."
  value       = var.enable_state_backend ? aws_s3_bucket.state[0].arn : ""
}

output "state_bucket_region" {
  description = "AWS region where the state bucket was created."
  value       = var.enable_state_backend ? aws_s3_bucket.state[0].region : ""
}

output "lock_table_id" {
  description = "Name of the DynamoDB table used for Terraform state locking."
  value       = var.enable_state_backend ? aws_dynamodb_table.locks[0].id : ""
}

output "lock_table_arn" {
  description = "ARN of the DynamoDB lock table."
  value       = var.enable_state_backend ? aws_dynamodb_table.locks[0].arn : ""
}

output "backend_config" {
  description = "Ready-to-use Terraform backend configuration block values. Paste into your root module's backend configuration."
  value = var.enable_state_backend ? {
    bucket         = aws_s3_bucket.state[0].id
    dynamodb_table = aws_dynamodb_table.locks[0].id
    region         = aws_s3_bucket.state[0].region
    encrypt        = true
  } : null
}

###############################################################################
# Organizations
###############################################################################

output "organization_id" {
  description = "ID of the AWS Organization. Empty string when enable_organizations is false and no existing org is found."
  value       = local.org_id
}

output "organization_root_id" {
  description = "ID of the organization root. Used for SCP attachments."
  value       = local.org_root_id
}

output "scp_deny_leave_org_id" {
  description = "ID of the SCP that prevents accounts from leaving the organization. Empty string when not created."
  value       = var.enable_organizations && var.enable_scp_deny_leave_org ? aws_organizations_policy.deny_leave_org[0].id : ""
}

###############################################################################
# CloudTrail
###############################################################################

output "cloudtrail_arn" {
  description = "ARN of the CloudTrail trail. Empty string when enable_cloudtrail is false."
  value       = var.enable_cloudtrail ? aws_cloudtrail.this[0].arn : ""
}

output "cloudtrail_home_region" {
  description = "Region where the CloudTrail trail was created."
  value       = var.enable_cloudtrail ? aws_cloudtrail.this[0].home_region : ""
}

output "cloudtrail_bucket_id" {
  description = "Name of the S3 bucket receiving CloudTrail logs."
  value       = var.enable_cloudtrail ? aws_s3_bucket.cloudtrail[0].id : ""
}

output "cloudtrail_bucket_arn" {
  description = "ARN of the CloudTrail log S3 bucket."
  value       = var.enable_cloudtrail ? aws_s3_bucket.cloudtrail[0].arn : ""
}

output "cloudtrail_kms_key_arn" {
  description = "ARN of the KMS key used to encrypt CloudTrail logs."
  value       = var.enable_cloudtrail ? aws_kms_key.cloudtrail[0].arn : ""
}

output "cloudtrail_kms_key_id" {
  description = "Key ID of the CloudTrail KMS key."
  value       = var.enable_cloudtrail ? aws_kms_key.cloudtrail[0].key_id : ""
}

output "cloudtrail_log_group_arn" {
  description = "ARN of the CloudWatch Log Group receiving CloudTrail events. Empty string when cloudtrail_log_retention_days is 0."
  value = (
    var.enable_cloudtrail && var.cloudtrail_log_retention_days > 0
    ? aws_cloudwatch_log_group.cloudtrail[0].arn
    : ""
  )
}

###############################################################################
# AWS Config
###############################################################################

output "config_recorder_id" {
  description = "Name of the AWS Config configuration recorder. Empty string when enable_config is false."
  value       = var.enable_config ? aws_config_configuration_recorder.this[0].id : ""
}

output "config_bucket_id" {
  description = "Name of the S3 bucket receiving AWS Config snapshots."
  value       = var.enable_config ? aws_s3_bucket.config[0].id : ""
}

output "config_role_arn" {
  description = "ARN of the IAM role used by AWS Config."
  value       = var.enable_config ? aws_iam_role.config[0].arn : ""
}

###############################################################################
# Budget
###############################################################################

output "budget_sns_topic_arn" {
  description = "ARN of the SNS topic used for budget alerts. Empty string when enable_budget_alarm is false."
  value       = var.enable_budget_alarm ? aws_sns_topic.budget[0].arn : ""
}

output "budget_name" {
  description = "Name of the AWS Budgets budget."
  value       = var.enable_budget_alarm ? aws_budgets_budget.monthly[0].name : ""
}

###############################################################################
# Account info (always available, useful to consuming modules)
###############################################################################

output "account_id" {
  description = "AWS account ID where the landing zone was deployed."
  value       = data.aws_caller_identity.current.account_id
}

output "region" {
  description = "AWS region where the landing zone was deployed."
  value       = data.aws_region.current.region
}
