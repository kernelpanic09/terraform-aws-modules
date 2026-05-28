# aws-backup

Terraform module that creates a production-grade AWS Backup configuration.

## Features

- Primary backup vault with AWS KMS encryption (key rotation enabled)
- Optional cross-region replica vault in a configurable destination region
- Backup vault lock in GOVERNANCE or COMPLIANCE mode for immutability
- Multiple backup plans, each with multiple rules (schedule, lifecycle, cross-region copy)
- Tag-based and/or explicit ARN-based resource selection per plan
- IAM role with the AWS-managed backup and restore managed policies
- SNS topic (KMS-encrypted) for backup event notifications with email subscriptions
- Optional automated restore testing plans (AWS Backup Restore Testing, GA 2024)
- Consistent tagging on every resource

## WARNING: COMPLIANCE Mode Vault Lock

Setting `vault_lock_mode = "COMPLIANCE"` is **irreversible** after the
`vault_lock_changeable_for_days` window expires.

Once a COMPLIANCE vault lock is active:
- No AWS principal, including the root account, can delete recovery points.
- The vault itself cannot be deleted until all recovery points have expired.
- The vault lock policy cannot be modified or removed.

**Do not enable COMPLIANCE mode without explicit sign-off from your security
and compliance teams.** Use GOVERNANCE mode for initial testing and
for environments where you need the option to remove the lock later.

## Usage

```hcl
module "backup" {
  source = "./module"

  name = "myapp-prod"

  enable_cross_region_copy = true
  replica_region           = "us-west-2"

  enable_vault_lock             = true
  vault_lock_mode               = "GOVERNANCE"
  vault_lock_min_retention_days = 7
  vault_lock_max_retention_days = 365

  backup_plans = [
    {
      name = "daily"
      rules = [
        {
          name                      = "daily-35day"
          schedule                  = "cron(0 5 * * ? *)"
          start_window_minutes      = 60
          completion_window_minutes = 180
          delete_after_days         = 35
          copy_to_replica           = true
          replica_delete_after_days = 35
        }
      ]
    }
  ]

  selection_tags = [
    { key = "backup", value = "true" }
  ]

  notification_emails = ["ops@example.com"]

  tags = {
    Environment = "prod"
    Team        = "platform"
  }
}
```

A provider alias is required when `enable_cross_region_copy = true`:

```hcl
provider "aws" {
  region = "us-east-1"
}

provider "aws" {
  alias  = "replica"
  region = "us-west-2"
}
```

Pass the alias to the module:

```hcl
module "backup" {
  source = "./module"

  providers = {
    aws         = aws
    aws.replica = aws.replica
  }

  # ... other variables
}
```

## Provider Requirements

| Name | Version |
|------|---------|
| aws | >= 5.40.0 |

The module declares two provider configurations internally:

- `aws` -- default, used for all primary region resources
- `aws.replica` -- alias required by the caller; used only when `enable_cross_region_copy = true`

The `aws.replica` provider alias must always be passed in the `providers` map
even when `enable_cross_region_copy = false`, because Terraform evaluates
provider requirements statically. Configure the alias to point to any valid
region (it will not create resources there unless cross-region copy is enabled).

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| name | string | required | Base name prefix for all resources. |
| kms_deletion_window | number | 30 | KMS key deletion window in days (7-30). |
| enable_cross_region_copy | bool | false | Enable secondary replica vault in another region. |
| replica_region | string | "" | Destination region for cross-region copies. |
| enable_vault_lock | bool | false | Apply a vault lock to the primary vault. |
| vault_lock_mode | string | "GOVERNANCE" | Lock mode: GOVERNANCE or COMPLIANCE. See warning above. |
| vault_lock_min_retention_days | number | 7 | Minimum retention enforced by the vault lock. |
| vault_lock_max_retention_days | number | 365 | Maximum retention enforced by the vault lock. |
| vault_lock_changeable_for_days | number | 3 | Days the lock remains editable before becoming permanent. |
| backup_plans | list(object) | required | List of backup plans. See backup_plans schema below. |
| selection_tags | list(object) | [] | Tags for tag-based resource selection. |
| selection_resources | list(string) | [] | Explicit resource ARNs to back up. |
| notification_emails | list(string) | [] | Email addresses subscribed to backup notifications. |
| notification_events | list(string) | (all events) | Backup event types that trigger notifications. |
| enable_restore_testing | bool | false | Create an automated restore testing plan. |
| restore_testing_schedule | string | weekly Sun 08:00 UTC | Cron schedule for restore tests. |
| restore_testing_start_window_hours | number | 4 | Hours after schedule before restore test times out. |
| restore_test_selection_tags | list(object) | [] | Tags filtering which recovery points are restore-tested. |
| tags | map(string) | {} | Tags applied to every resource. |

### backup_plans schema

```hcl
list(object({
  name = string
  rules = list(object({
    name                            = string
    schedule                        = string   # cron(0 5 * * ? *)
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
```

Rules with `enable_continuous_backup = true` are suitable for services that
support point-in-time recovery (PITR) such as RDS, DynamoDB, and EFS. The
schedule expression is still required but the backup runs continuously in the
background; the schedule controls when recovery points are created.

## Outputs

| Name | Description |
|------|-------------|
| primary_vault_id | Name/ID of the primary backup vault. |
| primary_vault_arn | ARN of the primary backup vault. |
| primary_vault_recovery_points | Current number of recovery points in the primary vault. |
| replica_vault_id | Name/ID of the replica vault (empty when disabled). |
| replica_vault_arn | ARN of the replica vault (empty when disabled). |
| kms_key_id | ID of the primary vault KMS key. |
| kms_key_arn | ARN of the primary vault KMS key. |
| replica_kms_key_arn | ARN of the replica vault KMS key (empty when disabled). |
| backup_role_arn | ARN of the IAM role used by AWS Backup. |
| backup_role_name | Name of the IAM role used by AWS Backup. |
| sns_topic_arn | ARN of the backup notifications SNS topic. |
| sns_topic_name | Name of the backup notifications SNS topic. |
| backup_plan_ids | Map of plan name to backup plan ID. |
| backup_plan_arns | Map of plan name to backup plan ARN. |
| backup_plan_versions | Map of plan name to plan version ID. |
| restore_testing_plan_name | Name of the restore testing plan (empty when disabled). |

## Cross-region copy architecture

When `enable_cross_region_copy = true` the module creates:

1. A KMS key in `replica_region` (via `aws.replica` provider).
2. A backup vault in `replica_region` encrypted with that key.
3. For each rule where `copy_to_replica = true`, a `copy_action` block that
   targets the replica vault ARN.

The replica vault uses independent lifecycle settings
(`replica_cold_storage_after_days`, `replica_delete_after_days`) so that
the replica can have a shorter or longer retention than the primary.

## Notification events

All events are subscribed by default. Override with the `notification_events`
variable. Available events:

```
BACKUP_JOB_STARTED
BACKUP_JOB_COMPLETED
BACKUP_JOB_FAILED
COPY_JOB_STARTED
COPY_JOB_SUCCESSFUL
COPY_JOB_FAILED
RESTORE_JOB_COMPLETED
RESTORE_JOB_FAILED
RECOVERY_POINT_MODIFIED
BACKUP_PLAN_CREATED
BACKUP_PLAN_MODIFIED
```

## Restore testing

AWS Backup Restore Testing (GA 2024) automates restore validation. When
`enable_restore_testing = true` the module creates a restore testing plan that:

- Runs on the `restore_testing_schedule` (default: weekly, Sunday 08:00 UTC)
- Selects the latest recovery point within the previous 24 hours from the
  primary vault
- Restores to a temporary EC2 instance and reports success/failure
- Optionally filters recovery points by `restore_test_selection_tags`

Restore test results appear in the AWS Backup console under
"Restore testing" and in CloudWatch metrics.

## Security notes

- The KMS key policy grants `backup.amazonaws.com` only the minimum actions
  required: `GenerateDataKey`, `Decrypt`, and `DescribeKey`.
- The SNS topic is encrypted with the same KMS key. The key policy also grants
  `sns.amazonaws.com` the actions required to publish encrypted messages.
- The IAM role uses AWS-managed policies (`AWSBackupServiceRolePolicyForBackup`
  and `AWSBackupServiceRolePolicyForRestores`). AWS maintains these policies;
  they are not pinned to a version in this module.
- Email subscriptions to the SNS topic require manual confirmation. Unconfirmed
  subscriptions expire after 3 days.

## License

Apache 2.0
