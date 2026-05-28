# AWS IAM Identity Center (SSO) Module

Manages the full AWS IAM Identity Center configuration as Terraform code. Most organizations configure Identity Center manually through the AWS console, meaning access changes require a human to log in, click through multiple screens, and leave no audit trail in source control. This module changes that: permission sets, groups, and account assignments are declared in code, reviewed via pull request, and applied automatically.

## Why This Matters

- **Audit trail**: every access change is a git commit with author and timestamp
- **Consistency**: permission sets are defined once and reused across accounts. no drift between environments
- **Speed**: granting a new team access to three accounts is a two-line change, not fifteen console clicks
- **Compliance**: policies-as-code integrate naturally with OPA/Conftest or custom CI checks

## Prerequisites

1. **AWS IAM Identity Center must already be enabled** in your AWS organization. Identity Center is a singleton per organization and cannot be created via Terraform. this module references the existing instance.
2. **Run this module from the management account** or from a delegated administrator account for IAM Identity Center.
3. The AWS provider must be configured with credentials that have sufficient permissions to manage Identity Center resources (`sso:*`, `identitystore:*`).

## Usage

```hcl
module "identity_center" {
  source = "../../modules/identity-center"

  permission_sets = [
    {
      name             = "Administrator"
      description      = "Full administrative access"
      session_duration = "PT2H"
      managed_policy_arns = [
        "arn:aws:iam::aws:policy/AdministratorAccess"
      ]
    },
    {
      name             = "Developer"
      description      = "Developer access. read/write to most services, no IAM or billing"
      session_duration = "PT8H"
      managed_policy_arns = [
        "arn:aws:iam::aws:policy/PowerUserAccess"
      ]
      inline_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid    = "DenyIAMMutations"
            Effect = "Deny"
            Action = [
              "iam:CreateUser",
              "iam:DeleteUser",
              "iam:AttachUserPolicy",
            ]
            Resource = "*"
          }
        ]
      })
    },
    {
      name             = "ReadOnly"
      description      = "Read-only access across all services"
      session_duration = "PT8H"
      managed_policy_arns = [
        "arn:aws:iam::aws:policy/ReadOnlyAccess"
      ]
    },
  ]

  groups = [
    {
      name        = "platform-admins"
      description = "Platform engineering team. full admin"
    },
    {
      name        = "developers"
      description = "Application developers"
    },
    {
      name        = "auditors"
      description = "Security and compliance auditors"
    },
  ]

  account_assignments = [
    {
      group_name          = "platform-admins"
      permission_set_name = "Administrator"
      account_ids         = ["111111111111", "222222222222"] # prod + staging
    },
    {
      group_name          = "developers"
      permission_set_name = "Developer"
      account_ids         = ["222222222222"] # staging only
    },
    {
      group_name          = "developers"
      permission_set_name = "ReadOnly"
      account_ids         = ["111111111111"] # read-only in prod
    },
    {
      group_name          = "auditors"
      permission_set_name = "ReadOnly"
      account_ids         = ["111111111111", "222222222222"]
    },
  ]

  tags = {
    Environment = "management"
    Team        = "platform"
  }
}
```

## How Account Assignments Work

An account assignment is a **triple**: group + permission set + AWS account. All three must be specified together. A single group can have multiple permission sets across multiple accounts, and each combination is tracked as an independent resource.

For example, `developers` having `Developer` access in `staging` and `ReadOnly` access in `prod` requires two separate entries in `account_assignments`. The module handles the flattening internally.

The resulting key for each assignment is `<group>-<permission_set>-<account_id>`, which is used as the Terraform resource key. Changing any part of the triple destroys and recreates that assignment.

## Common Patterns

### Adding a new team member

Members are added to Identity Center groups via the console or your IdP (Okta, Azure AD, etc.). Terraform manages the groups and their access. individual user membership is managed separately (or automatically via SCIM provisioning if you have an external IdP connected).

### Granting a team access to a new account

Add the new account ID to the relevant entry in `account_assignments` and apply:

```hcl
account_assignments = [
  {
    group_name          = "developers"
    permission_set_name = "Developer"
    account_ids         = ["222222222222", "333333333333"] # added sandbox account
  },
]
```

### Creating a permission set with a custom inline policy

Use the `inline_policy` field with `jsonencode`:

```hcl
{
  name             = "S3ReadOnly"
  description      = "Read-only access to specific S3 buckets"
  session_duration = "PT8H"
  inline_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:ListBucket"]
      Resource = ["arn:aws:s3:::my-bucket", "arn:aws:s3:::my-bucket/*"]
    }]
  })
}
```

### Shorter sessions for privileged access

Set `session_duration` in ISO 8601 duration format. For admin roles, a shorter session reduces the blast radius of a compromised session:

```hcl
{
  name             = "Administrator"
  session_duration = "PT1H"   # 1 hour
  ...
}
```

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `permission_sets` | List of permission sets to create | `list(object)` | `[]` | no |
| `groups` | List of Identity Store groups to create | `list(object)` | `[]` | no |
| `account_assignments` | Group-to-permission-set-to-account mappings | `list(object)` | `[]` | no |
| `tags` | Tags applied to all taggable resources | `map(string)` | `{}` | no |

### permission_sets object

| Field | Description | Type | Default |
|-------|-------------|------|---------|
| `name` | Permission set name (alphanumeric, hyphens, underscores) | `string` | required |
| `description` | Human-readable description | `string` | required |
| `session_duration` | ISO 8601 duration for the SSO session | `string` | `"PT4H"` |
| `relay_state` | URL to redirect to after login | `string` | `null` |
| `managed_policy_arns` | List of AWS managed policy ARNs to attach | `list(string)` | `[]` |
| `inline_policy` | JSON-encoded inline IAM policy document | `string` | `null` |

### groups object

| Field | Description | Type | Default |
|-------|-------------|------|---------|
| `name` | Group display name | `string` | required |
| `description` | Group description | `string` | `""` |

### account_assignments object

| Field | Description | Type | Default |
|-------|-------------|------|---------|
| `group_name` | Must match a name in `var.groups` | `string` | required |
| `permission_set_name` | Must match a name in `var.permission_sets` | `string` | required |
| `account_ids` | List of 12-digit AWS account IDs | `list(string)` | required |

## Outputs

| Name | Description |
|------|-------------|
| `instance_arn` | ARN of the Identity Center instance |
| `identity_store_id` | ID of the Identity Store |
| `permission_set_arns` | Map of permission set name to ARN |
| `group_ids` | Map of group name to Identity Store group ID |
| `assignment_keys` | List of account assignment resource IDs |

## Notes

- Identity Center is a singleton per AWS organization. The data source `aws_ssoadmin_instances` discovers the existing instance automatically.
- Destroying a permission set that has active assignments will fail. Remove assignments first.
- If you use an external IdP (Okta, Azure AD) with SCIM, user and group membership sync automatically. This module creates the groups that your IdP syncs into.
- Session duration must be in ISO 8601 duration format: `PT1H` (1 hour), `PT4H` (4 hours), `PT8H` (8 hours), `PT12H` (12 hours).
