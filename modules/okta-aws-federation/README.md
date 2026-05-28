# okta-aws-federation

Automates the complete Okta-to-AWS SAML federation setup that most organizations configure manually through the console. The module creates an Okta SAML application, an AWS IAM SAML Identity Provider seeded from Okta's live metadata, and one IAM role and Okta group per logical access tier -- all wired together so Okta group membership drives AWS role assumption with no additional configuration.

## Prerequisites

- **Okta API token** with permissions to manage applications and groups (set via `OKTA_API_TOKEN` environment variable or the `api_token` provider argument)
- **Okta org URL** (set via `OKTA_ORG_NAME` + `OKTA_BASE_URL` or the `org_name` / `base_url` provider arguments)
- **AWS credentials** with IAM write permissions (`iam:CreateSAMLProvider`, `iam:CreateRole`, `iam:AttachRolePolicy`, etc.)
- Terraform >= 1.5

## Usage

```hcl
provider "okta" {
  org_name  = "my-company"
  base_url  = "okta.com"
  api_token = var.okta_api_token
}

provider "aws" {
  region = "us-east-1"
}

module "okta_aws_federation" {
  source = "../../modules/okta-aws-federation"

  okta_app_label     = "Amazon Web Services"
  saml_provider_name = "Okta"
  okta_group_prefix  = "aws-"
  session_duration   = 3600

  roles = [
    {
      name        = "admin"
      description = "Full administrative access"
      policy_arns = ["arn:aws:iam::aws:policy/AdministratorAccess"]
    },
    {
      name        = "developer"
      description = "Developer access with read-only for sensitive services"
      policy_arns = [
        "arn:aws:iam::aws:policy/PowerUserAccess",
      ]
      inline_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Effect   = "Deny"
          Action   = ["iam:*", "organizations:*"]
          Resource = "*"
        }]
      })
    },
    {
      name        = "readonly"
      description = "Read-only access across all AWS services"
      policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
    },
  ]

  tags = {
    Environment = "production"
    Team        = "platform"
  }
}
```

## How the SAML attribute mapping works

When a user signs into AWS via Okta SSO, Okta constructs a SAML assertion containing three key attributes:

| SAML Attribute | Source | Purpose |
|---|---|---|
| `RoleSessionName` | `user.email` | Sets the session name visible in CloudTrail |
| `SessionDuration` | `var.session_duration` | Maximum length of the assumed-role session |
| `Role` | Okta group profile | Comma-separated `<role_arn>,<idp_arn>` pair that tells AWS which role to assume |

The `Role` attribute is populated from the Okta group's profile field. This module sets each group's profile to `"<role_arn>,<saml_provider_arn>"` -- the exact format AWS requires. The `filter_type = "STARTS_WITH"` on the Role attribute statement ensures only groups matching `var.okta_group_prefix` are included, preventing unrelated groups from leaking into the assertion.

Assigning a user to (for example) the `aws-developer` Okta group grants them the ability to assume the `developer` IAM role in AWS when they sign in through the Okta tile. Removing them from the group immediately revokes that access.

## Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|---|
| `okta_app_label` | Display label for the Okta SAML application | `string` | `"Amazon Web Services"` | no |
| `saml_provider_name` | Name for the IAM SAML Identity Provider in AWS | `string` | `"Okta"` | no |
| `okta_group_prefix` | Prefix applied to all Okta group names | `string` | `"aws-"` | no |
| `session_duration` | Maximum session duration in seconds (900-43200) | `number` | `3600` | no |
| `roles` | List of IAM roles to create with Okta group mapping | `list(object)` | n/a | yes |
| `tags` | Tags applied to all taggable AWS resources | `map(string)` | `{}` | no |

### roles object schema

| Field | Type | Description |
|---|---|---|
| `name` | `string` | IAM role name and suffix for the Okta group name |
| `description` | `string` | Human-readable description of the role's purpose |
| `policy_arns` | `list(string)` | AWS managed policy ARNs to attach to the role |
| `permissions_boundary_arn` | `optional(string)` | ARN of an IAM policy to set as the permissions boundary |
| `inline_policy` | `optional(string)` | JSON-encoded inline policy document to attach to the role |

## Outputs

| Name | Description |
|---|---|
| `saml_provider_arn` | ARN of the AWS IAM SAML Identity Provider |
| `okta_app_id` | ID of the Okta SAML application integration |
| `okta_app_metadata_url` | URL of the Okta SAML metadata document |
| `role_arns` | Map of role name to IAM role ARN |
| `role_names` | Map of role name to IAM role name |
| `okta_group_ids` | Map of role name to Okta group ID |
| `okta_group_names` | Map of role name to Okta group name |
| `saml_login_url` | Okta sign-in URL for the AWS tile |

## Security notes

**Session duration**: The default is 3600 seconds (1 hour). For highly privileged roles (admin), consider reducing to 900-1800 seconds to limit the blast radius of a stolen session token. For developer or readonly roles, up to 8 hours (28800) is reasonable for long working sessions without re-authentication interruptions.

**Permissions boundaries**: Use `permissions_boundary_arn` to cap the effective permissions of federated roles regardless of what managed or inline policies are attached. This is especially valuable in accounts where the federation roles themselves have IAM write access, preventing privilege escalation via role policy modification.

**Least privilege on Okta groups**: The Okta groups created by this module are empty by default. Assign users and automate group membership through Okta's HR-driven group rules or your IdP sync rather than manual assignment, so access follows the lifecycle of employment and team membership.

**SAML audience restriction**: The trust policy enforces `"SAML:aud" = "https://signin.aws.amazon.com/saml"`. This ensures the SAML assertion can only be used against the AWS SAML endpoint and cannot be replayed to other service providers.

**Metadata refresh**: The `okta_app_saml.aws.metadata` attribute is live -- Terraform will detect and apply changes if Okta rotates its signing certificate. Run `terraform apply` as part of certificate rotation runbooks to keep the IAM SAML provider in sync.
