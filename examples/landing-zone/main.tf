###############################################################################
# Example: Full landing zone bootstrap
#
# Deploys the complete landing-zone foundation for a new AWS management account:
#   - S3 remote state backend + DynamoDB locking
#   - AWS Organization with SCP guardrails
#   - Organization-wide CloudTrail with KMS encryption and CloudWatch Logs
#   - AWS Config recorder
#   - Monthly budget alarm with email notifications
#
# Bootstrap order:
#   1. Run with local state: terraform init && terraform apply
#   2. Commit the backend_config output values into your backend "s3" block
#   3. Run: terraform init -migrate-state
#   4. All subsequent runs use remote state
#
# Requirements: run from an IAM principal with OrganizationFullAccess and
# AdministratorAccess in the management account.
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
  }

  # Step 2: Uncomment and populate after the first local apply
  # backend "s3" {
  #   bucket         = "myorg-terraform-state-<account_id>"
  #   key            = "landing-zone/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "myorg-terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = var.environment
      ManagedBy   = "terraform"
      Project     = var.name
    }
  }
}

###############################################################################
# Variables
###############################################################################

variable "name" {
  description = "Base name for all landing zone resources."
  type        = string
  default     = "myorg"
}

variable "aws_region" {
  description = "Primary AWS region."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment label (typically 'management' for the root account)."
  type        = string
  default     = "management"
}

variable "budget_amount_usd" {
  description = "Monthly budget limit in USD."
  type        = number
  default     = 200
}

variable "alert_emails" {
  description = "Email addresses to receive budget and ops alerts."
  type        = list(string)
  default     = ["ops@example.com"]
}

###############################################################################
# Landing zone
###############################################################################

module "landing_zone" {
  source = "../../modules/landing-zone"

  name = var.name

  # --- Terraform state backend ---
  enable_state_backend                   = true
  state_bucket_versioning_enabled        = true
  state_bucket_lifecycle_noncurrent_days = 90
  state_bucket_force_destroy             = false
  dynamodb_billing_mode                  = "PAY_PER_REQUEST"

  # --- AWS Organization ---
  # Set to false if the organization already exists - import it first.
  enable_organizations = true

  organizations_aws_service_access_principals = [
    "cloudtrail.amazonaws.com",
    "config.amazonaws.com",
    "sso.amazonaws.com",
    "ram.amazonaws.com",
  ]

  organizations_enabled_policy_types = ["SERVICE_CONTROL_POLICY"]
  enable_scp_deny_leave_org          = true

  # --- CloudTrail ---
  enable_cloudtrail                        = true
  cloudtrail_is_organization_trail         = true # covers all member accounts
  cloudtrail_include_global_service_events = true
  cloudtrail_enable_log_file_validation    = true
  cloudtrail_log_retention_days            = 365
  cloudtrail_s3_key_prefix                 = "cloudtrail"

  # --- AWS Config ---
  enable_config                        = true
  config_delivery_frequency            = "TwentyFour_Hours"
  config_include_global_resource_types = true

  # --- Budget ---
  enable_budget_alarm            = true
  budget_limit_amount            = var.budget_amount_usd
  budget_alert_threshold_percent = 80
  budget_time_unit               = "MONTHLY"
  budget_alert_email_addresses   = var.alert_emails

  tags = {
    Environment = var.environment
    Project     = var.name
  }
}

###############################################################################
# Outputs - paste into your backend and share with team
###############################################################################

output "backend_config" {
  description = "Copy these values into your Terraform backend 's3' block after migration."
  value       = module.landing_zone.backend_config
}

output "state_bucket" {
  description = "Name of the Terraform state bucket."
  value       = module.landing_zone.state_bucket_id
}

output "lock_table" {
  description = "Name of the DynamoDB lock table."
  value       = module.landing_zone.lock_table_id
}

output "organization_id" {
  description = "AWS Organization ID."
  value       = module.landing_zone.organization_id
}

output "cloudtrail_arn" {
  description = "ARN of the organization-wide CloudTrail trail."
  value       = module.landing_zone.cloudtrail_arn
}

output "cloudtrail_kms_key_arn" {
  description = "ARN of the KMS key encrypting CloudTrail logs. Grant decrypt access to authorized roles."
  value       = module.landing_zone.cloudtrail_kms_key_arn
}

output "budget_sns_topic_arn" {
  description = "ARN of the budget alert SNS topic. Wire in additional subscribers (e.g., PagerDuty, Slack) here."
  value       = module.landing_zone.budget_sns_topic_arn
}

output "account_id" {
  description = "AWS account ID where the landing zone was bootstrapped."
  value       = module.landing_zone.account_id
}

output "region" {
  description = "AWS region of the landing zone."
  value       = module.landing_zone.region
}
