# landing-zone

Creates the foundational infrastructure for a well-architected, multi-account AWS environment. All major features are independently toggleable with `enable_*` flags.

## What this module creates

| Feature | Flag | Default |
|---------|------|---------|
| S3 state bucket + DynamoDB lock table | `enable_state_backend` | `true` |
| AWS Organization + SCP guardrails | `enable_organizations` | `false` |
| CloudTrail (multi-region, KMS-encrypted) + CloudWatch Logs | `enable_cloudtrail` | `true` |
| AWS Config recorder + delivery channel | `enable_config` | `false` |
| Monthly budget alarm via SNS + email | `enable_budget_alarm` | `true` |

### S3 state bucket

- Named `{name}-terraform-state-{account_id}` - globally unique without coordination.
- Versioning enabled, non-current versions transitioned to IA after 30 days and expired after the configurable `lifecycle_noncurrent_days`.
- SSE-KMS with bucket key enabled (reduces KMS API calls and cost).
- Public access fully blocked; bucket policy enforces TLS-only access.

### DynamoDB lock table

- Named `{name}-terraform-locks`.
- Pay-per-request by default (no capacity planning needed for state locking).
- Point-in-time recovery and server-side encryption enabled.

### AWS Organizations

- Enables ALL features (SCPs, tag policies, etc.).
- Attaches an SCP to the root that prevents `organizations:LeaveOrganization`.
- Trusted access enabled for CloudTrail, Config, and SSO by default.
- Only run with `enable_organizations = true` from the management account.

### CloudTrail

- Multi-region trail with global service events and log file validation.
- Encrypted with a dedicated KMS key (key policy grants CloudTrail encrypt, account root full management).
- Logs delivered to S3 with lifecycle: IA at 90d, Glacier at 1yr, expired at 7yr.
- CloudWatch Logs delivery optional (disable by setting `cloudtrail_log_retention_days = 0`).

### Budget alarm

- Dual notifications: actual spend and forecasted spend both trigger at the configured percentage.
- SNS email subscriptions created for each address in `budget_alert_email_addresses`. Email confirmation is required by AWS before delivery.

## Usage

### Minimal bootstrap

```hcl
module "landing_zone" {
  source = "./modules/landing-zone"

  name = "myorg"

  budget_limit_amount          = 200
  budget_alert_email_addresses = ["ops@example.com"]

  tags = {
    Environment = "management"
    Team        = "platform"
  }
}
```

### Full setup with Organizations and Config

```hcl
module "landing_zone" {
  source = "./modules/landing-zone"

  name = "myorg"

  # State backend
  enable_state_backend                   = true
  state_bucket_lifecycle_noncurrent_days = 90

  # Organizations (run from management account only)
  enable_organizations    = true
  enable_scp_deny_leave_org = true

  # CloudTrail - org-wide
  enable_cloudtrail                = true
  cloudtrail_is_organization_trail = true
  cloudtrail_log_retention_days    = 365

  # Config
  enable_config = true

  # Budget
  enable_budget_alarm          = true
  budget_limit_amount          = 500
  budget_alert_threshold_percent = 80
  budget_alert_email_addresses = ["finance@example.com", "cto@example.com"]

  tags = {
    Environment = "management"
    Team        = "platform"
  }
}
```

### Use the backend config output

After the first apply, copy the backend configuration into your workspace:

```hcl
terraform {
  backend "s3" {
    bucket         = "myorg-terraform-state-123456789012"
    key            = "global/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "myorg-terraform-locks"
    encrypt        = true
  }
}
```

Or read it from the output:

```bash
terraform output -json backend_config
```

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.5.0 |
| aws | >= 5.0.0 |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| name | Base name for all resources | `string` | - | yes |
| tags | Tags applied to all resources | `map(string)` | `{}` | no |
| enable_state_backend | Create S3 state bucket + DynamoDB | `bool` | `true` | no |
| state_bucket_force_destroy | Allow destroying non-empty state bucket | `bool` | `false` | no |
| state_bucket_versioning_enabled | Enable bucket versioning | `bool` | `true` | no |
| state_bucket_lifecycle_noncurrent_days | Days before expiring old state versions | `number` | `90` | no |
| dynamodb_billing_mode | PAY_PER_REQUEST or PROVISIONED | `string` | `"PAY_PER_REQUEST"` | no |
| dynamodb_read_capacity | DynamoDB RCUs (PROVISIONED only) | `number` | `5` | no |
| dynamodb_write_capacity | DynamoDB WCUs (PROVISIONED only) | `number` | `5` | no |
| enable_organizations | Create/manage the AWS Organization | `bool` | `false` | no |
| organizations_aws_service_access_principals | Service principals with org trusted access | `list(string)` | CloudTrail, Config, SSO | no |
| organizations_enabled_policy_types | Policy types enabled on root | `list(string)` | `["SERVICE_CONTROL_POLICY"]` | no |
| enable_scp_deny_leave_org | Attach deny-LeaveOrganization SCP | `bool` | `true` | no |
| enable_cloudtrail | Create CloudTrail trail | `bool` | `true` | no |
| cloudtrail_name | Override trail name | `string` | `""` | no |
| cloudtrail_is_organization_trail | Make trail org-wide | `bool` | `false` | no |
| cloudtrail_include_global_service_events | Include IAM/STS events | `bool` | `true` | no |
| cloudtrail_enable_log_file_validation | Validate log integrity | `bool` | `true` | no |
| cloudtrail_log_retention_days | CW Logs retention (0 = disable) | `number` | `365` | no |
| cloudtrail_s3_key_prefix | S3 prefix for log delivery | `string` | `"cloudtrail"` | no |
| enable_config | Create AWS Config recorder | `bool` | `false` | no |
| config_delivery_frequency | Snapshot delivery interval | `string` | `"TwentyFour_Hours"` | no |
| config_include_global_resource_types | Record IAM resources | `bool` | `true` | no |
| enable_budget_alarm | Create budget alert | `bool` | `true` | no |
| budget_limit_amount | Monthly budget USD | `number` | `100` | no |
| budget_alert_threshold_percent | Alert at this % of limit | `number` | `80` | no |
| budget_alert_email_addresses | Email addresses for SNS subscriptions | `list(string)` | `[]` | no |
| budget_time_unit | DAILY, MONTHLY, QUARTERLY, ANNUALLY | `string` | `"MONTHLY"` | no |

## Outputs

| Name | Description |
|------|-------------|
| state_bucket_id | Name of the Terraform state S3 bucket |
| state_bucket_arn | ARN of the state bucket |
| state_bucket_region | Region of the state bucket |
| lock_table_id | Name of the DynamoDB lock table |
| lock_table_arn | ARN of the lock table |
| backend_config | Map of backend config values (bucket, dynamodb_table, region, encrypt) |
| organization_id | AWS Organization ID |
| organization_root_id | Organization root ID |
| scp_deny_leave_org_id | ID of the deny-leave SCP |
| cloudtrail_arn | ARN of the CloudTrail trail |
| cloudtrail_home_region | Region of the trail |
| cloudtrail_bucket_id | Name of the CloudTrail log bucket |
| cloudtrail_bucket_arn | ARN of the CloudTrail log bucket |
| cloudtrail_kms_key_arn | ARN of the CloudTrail KMS key |
| cloudtrail_kms_key_id | Key ID of the CloudTrail KMS key |
| cloudtrail_log_group_arn | ARN of the CloudWatch Log Group |
| config_recorder_id | Name of the Config recorder |
| config_bucket_id | Name of the Config S3 bucket |
| config_role_arn | ARN of the Config IAM role |
| budget_sns_topic_arn | ARN of the budget SNS topic |
| budget_name | Name of the budget |
| account_id | Deploying account ID |
| region | Deploying region |

## Notes

- Run `terraform state backend` migration after the first apply. The state bucket cannot host its own creation state - bootstrap locally then migrate.
- The CloudTrail bucket applies a 7-year retention policy (2557 days) to satisfy common compliance frameworks (SOC 2, PCI DSS, HIPAA). Adjust in the lifecycle configuration if shorter retention is acceptable.
- Budget alert emails require manual confirmation from AWS before delivery begins. Check the inbox for each address in `budget_alert_email_addresses` after apply.
- The `enable_organizations` flag imports or creates the organization. If the organization already exists, import it first: `terraform import module.landing_zone.aws_organizations_organization.this[0] <org-id>`.
