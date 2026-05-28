# ------------------------------------------------------------------------------
# GuardDuty
# ------------------------------------------------------------------------------

output "guardduty_detector_id" {
  description = "ID of the GuardDuty detector. Use this to reference the detector in member account associations or findings filters."
  value       = aws_guardduty_detector.this.id
}

output "guardduty_detector_arn" {
  description = "ARN of the GuardDuty detector."
  value       = aws_guardduty_detector.this.arn
}

# ------------------------------------------------------------------------------
# Security Hub
# ------------------------------------------------------------------------------

output "security_hub_account_id" {
  description = "AWS account ID where Security Hub is enabled. Null when enable_security_hub = false."
  value       = var.enable_security_hub ? data.aws_caller_identity.current.account_id : null
}

# ------------------------------------------------------------------------------
# SNS topics
# ------------------------------------------------------------------------------

output "high_severity_topic_arn" {
  description = "ARN of the SNS topic that receives HIGH and CRITICAL severity GuardDuty findings (severity >= 7). Subscribe additional endpoints (PagerDuty, Slack webhook, etc.) to this topic."
  value       = aws_sns_topic.high_severity.arn
}

output "medium_severity_topic_arn" {
  description = "ARN of the SNS topic that receives MEDIUM severity GuardDuty findings (severity >= 4 and < 7)."
  value       = aws_sns_topic.medium_severity.arn
}

# ------------------------------------------------------------------------------
# KMS
# ------------------------------------------------------------------------------

output "kms_key_arn" {
  description = "ARN of the KMS key used to encrypt SNS messages. Grant kms:Decrypt to additional consumers (e.g., Lambda functions that read from the encrypted topics via SQS)."
  value       = aws_kms_key.sns.arn
}

output "kms_key_id" {
  description = "ID (not ARN) of the KMS key. Use this to create additional key aliases."
  value       = aws_kms_key.sns.key_id
}

# ------------------------------------------------------------------------------
# Lambda auto-remediation
# ------------------------------------------------------------------------------

output "remediation_lambda_arn" {
  description = "ARN of the auto-remediation Lambda function. Null when enable_auto_remediation = false."
  value       = var.enable_auto_remediation ? aws_lambda_function.remediation[0].arn : null
}

output "remediation_lambda_name" {
  description = "Name of the auto-remediation Lambda function. Null when enable_auto_remediation = false."
  value       = var.enable_auto_remediation ? aws_lambda_function.remediation[0].function_name : null
}

output "remediation_role_arn" {
  description = "ARN of the IAM execution role attached to the remediation Lambda. Attach additional policies here to extend remediation capabilities. Null when enable_auto_remediation = false."
  value       = var.enable_auto_remediation ? aws_iam_role.remediation[0].arn : null
}

# ------------------------------------------------------------------------------
# EventBridge
# ------------------------------------------------------------------------------

output "eventbridge_rule_arns" {
  description = "Map of EventBridge rule names to their ARNs. Keys: high_severity, medium_severity."
  value = {
    high_severity   = aws_cloudwatch_event_rule.high_severity.arn
    medium_severity = aws_cloudwatch_event_rule.medium_severity.arn
  }
}
