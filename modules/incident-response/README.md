# incident-response

Provisions a complete security operations pipeline in a single `terraform apply`. The module wires together GuardDuty threat detection, Security Hub compliance aggregation, EventBridge routing, encrypted SNS alerting, and an auto-remediation Lambda that takes immediate action on common high-severity findings.

## Architecture

```
                        +----------------+
                        |   GuardDuty    |
                        | (detector +    |
                        |  data sources) |
                        +-------+--------+
                                |
                    GuardDuty Finding event
                                |
                        +-------v--------+
                        |  EventBridge   |
                        |  (two rules)   |
                        +---+--------+---+
                            |        |
               severity>=7  |        |  severity 4-6
                            |        |
               +------------v--+  +--v--------------+
               | SNS: high     |  | SNS: medium     |
               | (KMS-enc.)    |  | (KMS-enc.)      |
               +-------+-------+  +-----------------+
                       |
              +--------+--------+
              |                 |
        +-----v------+   +------v-------+
        | Email subs |   | Lambda:      |
        | (alert_    |   | remediation  |
        |  emails)   |   +------+-------+
        +------------+          |
                                | auto-remediates:
                                | - disable IAM key
                                | - block S3 public access
                                | - revoke 0.0.0.0/0 SG rules
                                |
                        +-------v--------+
                        | CloudWatch     |
                        | Alarm (errors) |
                        +-------+--------+
                                |
                        +-------v--------+
                        | SNS: high      |
                        | (Lambda error  |
                        |  notification) |
                        +----------------+

                        +----------------+
                        | Security Hub   |  <-- aggregates GuardDuty findings
                        | CIS 1.4.0      |      alongside compliance controls
                        | FSBP 1.0.0     |
                        +----------------+
```

## Auto-remediation actions

| GuardDuty finding type | Remediation action |
|---|---|
| `UnauthorizedAccess:IAMUser/*`, `CredentialAccess:*` | Calls `iam:UpdateAccessKey` to set the access key to `Inactive` |
| `Policy:S3/BucketPublicAccessGranted`, `Policy:S3/BucketAnonymousAccessGranted` | Calls `s3:PutBucketPublicAccessBlock` with all four block settings enabled |
| `UnauthorizedAccess:EC2/OpenSG` | Calls `ec2:RevokeSecurityGroupIngress` to remove all `0.0.0.0/0` and `::/0` ingress rules from the referenced security group |
| All other finding types | Logs the finding type and returns without taking action |

Remediation runs only for findings with severity >= 7. Lambda errors trigger a CloudWatch alarm that publishes to the high-severity SNS topic so failures are visible immediately.

## Usage

```hcl
module "incident_response" {
  source = "../../modules/incident-response"

  name = "prod"

  # GuardDuty data sources
  enable_s3_protection      = true
  enable_k8s_protection     = true   # set true if you run EKS
  enable_malware_protection = false  # incurs per-GB EBS scan cost

  # Compliance aggregation
  enable_security_hub = true

  # Automated response
  enable_auto_remediation = true

  # Alert routing
  alert_emails = [
    "security-team@example.com",
    "oncall@example.com",
  ]

  finding_publishing_frequency = "FIFTEEN_MINUTES"

  tags = {
    Environment = "production"
    Team        = "security"
    CostCenter  = "infra"
  }
}

output "high_severity_topic_arn" {
  value = module.incident_response.high_severity_topic_arn
}
```

## Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|---|
| `name` | Name prefix for all resources (1-32 chars, lowercase alphanumeric + hyphens) | `string` | - | yes |
| `enable_s3_protection` | Enable GuardDuty S3 data-plane monitoring | `bool` | `true` | no |
| `enable_k8s_protection` | Enable GuardDuty EKS audit log monitoring | `bool` | `false` | no |
| `enable_malware_protection` | Enable GuardDuty EBS volume malware scanning | `bool` | `false` | no |
| `enable_security_hub` | Enable Security Hub with CIS 1.4.0 and FSBP 1.0.0 standards | `bool` | `true` | no |
| `enable_auto_remediation` | Deploy the auto-remediation Lambda | `bool` | `true` | no |
| `finding_publishing_frequency` | GuardDuty subsequent-finding publish cadence: `FIFTEEN_MINUTES`, `ONE_HOUR`, or `SIX_HOURS` | `string` | `"FIFTEEN_MINUTES"` | no |
| `alert_emails` | Email addresses subscribed to both severity SNS topics | `list(string)` | `[]` | no |
| `tags` | Additional tags merged onto all resources | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|---|---|
| `guardduty_detector_id` | ID of the GuardDuty detector |
| `guardduty_detector_arn` | ARN of the GuardDuty detector |
| `security_hub_account_id` | Account ID where Security Hub is enabled (null if disabled) |
| `high_severity_topic_arn` | ARN of the SNS topic for HIGH/CRITICAL findings (severity >= 7) |
| `medium_severity_topic_arn` | ARN of the SNS topic for MEDIUM findings (severity 4-6) |
| `kms_key_arn` | ARN of the KMS key encrypting SNS messages |
| `kms_key_id` | ID of the KMS key (for creating additional aliases) |
| `remediation_lambda_arn` | ARN of the auto-remediation Lambda (null if disabled) |
| `remediation_lambda_name` | Name of the auto-remediation Lambda (null if disabled) |
| `remediation_role_arn` | ARN of the Lambda IAM execution role (null if disabled) |
| `eventbridge_rule_arns` | Map of `high_severity` and `medium_severity` EventBridge rule ARNs |

## Operational notes

### Email subscription confirmation

SNS email subscriptions are created in a `PendingConfirmation` state. Every address in `alert_emails` receives a confirmation email from AWS immediately after `terraform apply`. The subscription remains inactive until the link in that email is clicked. No alerts are delivered to unconfirmed addresses.

To subscribe non-email endpoints (PagerDuty, Slack via webhook, OpsGenie), create `aws_sns_topic_subscription` resources pointing at `module.incident_response.high_severity_topic_arn` after applying this module.

### Lambda error alerting

If the remediation Lambda throws an unhandled exception the error is logged to CloudWatch Logs (`/aws/lambda/<name>-security-remediation`) and the `<name>-remediation-errors` CloudWatch alarm transitions to `ALARM`, sending a notification to the high-severity SNS topic. This means a failed remediation attempt triggers the same human-alert path as the original finding.

### GuardDuty finding publishing frequency

The `finding_publishing_frequency` variable controls how often GuardDuty re-publishes *subsequent occurrences* of an existing finding. Initial (first-occurrence) findings are always published immediately regardless of this setting. For production environments `FIFTEEN_MINUTES` is recommended to balance alert fidelity with EventBridge invocation cost.

### Security Hub standards and cost

Security Hub charges per security check per resource per month. With CIS 1.4.0 and FSBP 1.0.0 both enabled, expect approximately 200-300 controls active in a typical account. Review the AWS pricing page before enabling in large multi-account environments.

### GuardDuty malware protection cost

When `enable_malware_protection = true`, GuardDuty scans EBS volumes attached to EC2 instances with active findings. Cost is per GB of volume scanned. Disable this in development environments to avoid unexpected charges.

### Extending auto-remediation

The IAM execution role ARN is exported as `remediation_role_arn`. Attach additional inline or managed policies to extend what the Lambda can remediate. The Lambda code is embedded in the module via `archive_file`; to customise the logic, fork the module and edit the `PYTHON` heredoc in `main.tf`.

### Multi-account / Organizations

To deploy across an AWS Organization, use GuardDuty delegated administrator and Security Hub central configuration in the management account, then instantiate this module once per member account (or use a Terraform `for_each` over account IDs). GuardDuty findings from member accounts flow to the delegated administrator account's EventBridge bus, which requires additional cross-account event bus policy configuration not included in this module.

## Requirements

| Name | Version |
|---|---|
| terraform | >= 1.5 |
| hashicorp/aws | >= 5.0 |
| hashicorp/archive | >= 2.0 |
