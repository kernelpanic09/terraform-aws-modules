# iam-roles

Creates a standard set of IAM roles for a well-architected AWS account:

- **Admin** - AdministratorAccess with optional MFA enforcement and configurable trust (cross-account, SAML, or Identity Center).
- **Read-only** - ReadOnlyAccess + SecurityAudit for auditors and on-call responders.
- **Developer** - Custom policy covering ECS, ECR, S3, CloudWatch, and SSM. Explicit deny on IAM/Organizations write actions prevents privilege escalation.
- **CI/CD** - AssumeRoleWithWebIdentity trust for GitHub Actions via OIDC. Creates (or references) the GitHub OIDC provider automatically.

All non-admin roles support an optional permissions boundary.

## Usage

### Minimal - cross-account admin + GitHub OIDC CI/CD

```hcl
module "iam_roles" {
  source = "./modules/iam-roles"

  name_prefix = "myorg"

  # Trust the ops account to assume admin
  admin_trusted_account_ids = ["123456789012"]

  # GitHub Actions OIDC for a specific repo
  github_org          = "my-github-org"
  github_repositories = ["infra"]
  github_branches     = ["ref:refs/heads/main"]
  cicd_extra_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonECR_FullAccess",
  ]

  tags = {
    Environment = "production"
    Team        = "platform"
  }
}
```

### Identity Center (SSO) trust

```hcl
module "iam_roles" {
  source = "./modules/iam-roles"

  name_prefix = "myorg"

  admin_trusted_identity_center     = true
  readonly_trusted_identity_center  = true
  developer_trusted_identity_center = true

  # Don't create OIDC roles when only using SSO
  create_cicd_role = false

  tags = { Environment = "production" }
}
```

### With permissions boundary

```hcl
module "iam_roles" {
  source = "./modules/iam-roles"

  name_prefix              = "myorg"
  permissions_boundary_arn = "arn:aws:iam::111122223333:policy/DeveloperBoundary"

  admin_trusted_account_ids     = ["111122223333"]
  developer_trusted_account_ids = ["111122223333"]

  github_org          = "my-github-org"
  github_repositories = ["*"]

  tags = { Environment = "staging" }
}
```

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.5.0 |
| aws | >= 5.0.0 |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| name_prefix | Prefix for all IAM resource names | `string` | - | yes |
| tags | Tags applied to all resources | `map(string)` | `{}` | no |
| permissions_boundary_arn | Permissions boundary ARN for non-admin roles | `string` | `""` | no |
| create_admin_role | Create the admin role | `bool` | `true` | no |
| admin_role_name | Override admin role name | `string` | `""` | no |
| admin_session_duration | Max session seconds (900-43200) | `number` | `3600` | no |
| admin_require_mfa | Require MFA in admin trust policy | `bool` | `true` | no |
| admin_trusted_account_ids | Account IDs that can assume admin | `list(string)` | `[]` | no |
| admin_trusted_saml_provider_arns | SAML providers for admin federation | `list(string)` | `[]` | no |
| admin_trusted_identity_center | Trust AWS Identity Center for admin | `bool` | `false` | no |
| create_readonly_role | Create the read-only role | `bool` | `true` | no |
| readonly_role_name | Override read-only role name | `string` | `""` | no |
| readonly_session_duration | Max session seconds (900-43200) | `number` | `3600` | no |
| readonly_trusted_account_ids | Account IDs that can assume read-only | `list(string)` | `[]` | no |
| readonly_trusted_identity_center | Trust AWS Identity Center for read-only | `bool` | `false` | no |
| create_developer_role | Create the developer role | `bool` | `true` | no |
| developer_role_name | Override developer role name | `string` | `""` | no |
| developer_session_duration | Max session seconds (900-43200) | `number` | `7200` | no |
| developer_trusted_account_ids | Account IDs that can assume developer | `list(string)` | `[]` | no |
| developer_trusted_identity_center | Trust AWS Identity Center for developer | `bool` | `false` | no |
| developer_extra_policy_arns | Extra managed policies for developer | `list(string)` | `[]` | no |
| developer_allowed_s3_bucket_arns | S3 ARNs scoped in developer policy | `list(string)` | `["arn:aws:s3:::*", "arn:aws:s3:::*/*"]` | no |
| create_cicd_role | Create the GitHub Actions OIDC role | `bool` | `true` | no |
| cicd_role_name | Override CI/CD role name | `string` | `""` | no |
| cicd_session_duration | Max session seconds (900-43200) | `number` | `3600` | no |
| github_org | GitHub org/username for OIDC trust | `string` | `""` | no |
| github_repositories | Repos allowed to assume CI/CD role | `list(string)` | `["*"]` | no |
| github_branches | Branch/tag/env patterns for OIDC sub claim | `list(string)` | `["*"]` | no |
| create_github_oidc_provider | Create the GitHub OIDC provider | `bool` | `true` | no |
| cicd_extra_policy_arns | Extra managed policies for CI/CD | `list(string)` | `[]` | no |
| cicd_permissions_boundary_arn | Override boundary for CI/CD role only | `string` | `""` | no |

## Outputs

| Name | Description |
|------|-------------|
| admin_role_arn | ARN of the admin role |
| admin_role_name | Name of the admin role |
| admin_role_unique_id | Stable unique ID of the admin role |
| readonly_role_arn | ARN of the read-only role |
| readonly_role_name | Name of the read-only role |
| readonly_role_unique_id | Stable unique ID of the read-only role |
| developer_role_arn | ARN of the developer role |
| developer_role_name | Name of the developer role |
| developer_role_unique_id | Stable unique ID of the developer role |
| developer_policy_arn | ARN of the custom developer policy |
| cicd_role_arn | ARN of the CI/CD role |
| cicd_role_name | Name of the CI/CD role |
| cicd_role_unique_id | Stable unique ID of the CI/CD role |
| github_oidc_provider_arn | ARN of the GitHub OIDC provider |
| role_arns | Map of role key to ARN for all created roles |

## Security notes

- The admin role enforces MFA by default (`admin_require_mfa = true`). Disable only for Identity Center / SAML trusts where MFA is handled by the IdP.
- All non-admin roles accept a permissions boundary. Use one to cap the blast radius of role misuse even if the role's policies are overly broad.
- The CI/CD role subject claim is scoped to `repo:{org}/{repo}:{ref}`. Pin `github_branches` to `ref:refs/heads/main` or `environment:production` for production deployments instead of allowing `*`.
- The developer policy contains an explicit `Deny` on IAM write and Organizations actions to prevent privilege escalation even if additional permissive policies are attached later.
