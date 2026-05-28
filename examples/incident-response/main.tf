terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# ---------------------------------------------------------------------------
# Example: full incident-response pipeline for a production account
#
# What this provisions:
#   - GuardDuty with S3 and Kubernetes protection enabled
#   - Security Hub (CIS 1.4.0 + FSBP 1.0.0)
#   - KMS-encrypted SNS topics for high and medium severity alerts
#   - Auto-remediation Lambda (disable IAM keys, block public S3, revoke open SGs)
#   - CloudWatch alarm on Lambda errors
#
# After apply:
#   1. Confirm the email subscriptions that arrive in your inbox.
#   2. To test GuardDuty, use the "Generate sample findings" button in the
#      AWS Console (GuardDuty > Settings > Sample findings).
#   3. Watch the high-severity SNS topic and Lambda CloudWatch Logs for activity.
# ---------------------------------------------------------------------------

module "incident_response" {
  source = "../../modules/incident-response"

  name = "prod"

  # GuardDuty data sources
  enable_s3_protection      = true
  enable_k8s_protection     = true   # set false if you do not run EKS
  enable_malware_protection = false  # incurs per-GB EBS scan cost; enable with caution

  # Compliance aggregation
  enable_security_hub = true

  # Automated response to high-severity findings
  enable_auto_remediation = true

  # Human alert routing (SNS email subscriptions)
  # Each address receives a confirmation email that must be accepted before
  # alerts are delivered.
  alert_emails = [
    "security-team@example.com",
  ]

  # How often GuardDuty re-publishes subsequent occurrences of existing findings.
  # Initial findings are always published immediately.
  finding_publishing_frequency = "FIFTEEN_MINUTES"

  tags = {
    Environment = "production"
    Team        = "security"
    CostCenter  = "platform"
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "guardduty_detector_id" {
  description = "GuardDuty detector ID for this account."
  value       = module.incident_response.guardduty_detector_id
}

output "high_severity_topic_arn" {
  description = "SNS topic ARN for HIGH/CRITICAL findings. Subscribe PagerDuty or Slack here."
  value       = module.incident_response.high_severity_topic_arn
}

output "medium_severity_topic_arn" {
  description = "SNS topic ARN for MEDIUM findings."
  value       = module.incident_response.medium_severity_topic_arn
}

output "remediation_lambda_arn" {
  description = "ARN of the auto-remediation Lambda."
  value       = module.incident_response.remediation_lambda_arn
}

output "remediation_role_arn" {
  description = "IAM role ARN for the remediation Lambda. Attach additional policies here to extend coverage."
  value       = module.incident_response.remediation_role_arn
}

output "kms_key_arn" {
  description = "KMS key ARN used to encrypt SNS messages."
  value       = module.incident_response.kms_key_arn
}

output "eventbridge_rule_arns" {
  description = "EventBridge rule ARNs keyed by severity band."
  value       = module.incident_response.eventbridge_rule_arns
}
