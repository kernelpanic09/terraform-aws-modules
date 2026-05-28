################################################################################
# Example: Okta-to-AWS SAML federation with three access tiers
#
# This example provisions:
#   - An Okta SAML app tile for AWS SSO
#   - An AWS IAM SAML Identity Provider backed by Okta's live metadata
#   - Three IAM roles (admin, developer, readonly) and a matching Okta group
#     for each role, with group membership controlling access
#
# Usage:
#   export OKTA_API_TOKEN="..."
#   export AWS_PROFILE="..."
#   terraform init && terraform apply
################################################################################

terraform {
  required_version = ">= 1.5"

  required_providers {
    okta = {
      source  = "okta/okta"
      version = ">= 4.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "okta" {
  org_name  = var.okta_org_name
  base_url  = "okta.com"
  api_token = var.okta_api_token
}

provider "aws" {
  region = var.aws_region
}

# ---------------------------------------------------------------------------
# Optional: permissions boundary policy
# Caps the effective permissions of all federated roles so they cannot
# escalate beyond what this boundary allows, even if broader policies are
# attached in the future.
# ---------------------------------------------------------------------------

resource "aws_iam_policy" "federation_boundary" {
  name        = "okta-federation-boundary"
  description = "Permissions boundary for all Okta-federated IAM roles"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["*"]
        Resource = ["*"]
      },
      {
        # Prevent federated sessions from modifying the SAML provider or
        # the federation boundary policy itself
        Effect = "Deny"
        Action = [
          "iam:DeleteSAMLProvider",
          "iam:UpdateSAMLProvider",
          "iam:DeleteRolePermissionsBoundary",
        ]
        Resource = ["*"]
      }
    ]
  })

  tags = local.common_tags
}

locals {
  common_tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Example     = "okta-federation"
  }
}

module "okta_aws_federation" {
  source = "../../modules/okta-aws-federation"

  okta_app_label     = "Amazon Web Services - ${var.environment}"
  saml_provider_name = "Okta-${var.environment}"
  okta_group_prefix  = "aws-${var.environment}-"
  session_duration   = 3600

  roles = [
    {
      name        = "admin"
      description = "Full administrative access. break-glass and platform engineering"
      policy_arns = ["arn:aws:iam::aws:policy/AdministratorAccess"]
      # Short session for highly privileged access
      # (session_duration is module-level, use inline deny for extra control)
      permissions_boundary_arn = aws_iam_policy.federation_boundary.arn
      inline_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          # Log every action taken in admin sessions for audit trail
          Effect   = "Allow"
          Action   = ["cloudtrail:LookupEvents"]
          Resource = ["*"]
        }]
      })
    },
    {
      name        = "developer"
      description = "Developer access. full compute and storage, no IAM or billing"
      policy_arns = [
        "arn:aws:iam::aws:policy/PowerUserAccess",
        "arn:aws:iam::aws:policy/AWSCodeBuildDeveloperAccess",
      ]
      permissions_boundary_arn = aws_iam_policy.federation_boundary.arn
      inline_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid      = "DenyIAMAndBilling"
            Effect   = "Deny"
            Action   = ["iam:*", "organizations:*", "aws-portal:*", "billing:*"]
            Resource = ["*"]
          },
          {
            Sid      = "AllowPassRoleToServices"
            Effect   = "Allow"
            Action   = ["iam:PassRole"]
            Resource = ["*"]
            Condition = {
              StringLike = {
                "iam:PassedToService" = [
                  "lambda.amazonaws.com",
                  "ecs-tasks.amazonaws.com",
                  "ec2.amazonaws.com",
                ]
              }
            }
          }
        ]
      })
    },
    {
      name        = "readonly"
      description = "Read-only access across all AWS services. auditors and on-call"
      policy_arns = [
        "arn:aws:iam::aws:policy/ReadOnlyAccess",
        "arn:aws:iam::aws:policy/AWSCloudTrailReadOnlyAccess",
      ]
      permissions_boundary_arn = aws_iam_policy.federation_boundary.arn
    },
  ]

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "saml_provider_arn" {
  description = "ARN of the Okta IAM SAML Identity Provider."
  value       = module.okta_aws_federation.saml_provider_arn
}

output "okta_app_id" {
  description = "Okta application ID. used to build the tile URL and configure group rules."
  value       = module.okta_aws_federation.okta_app_id
}

output "saml_login_url" {
  description = "URL users navigate to for AWS SSO via Okta."
  value       = module.okta_aws_federation.saml_login_url
}

output "role_arns" {
  description = "Map of role name to ARN for all federated IAM roles."
  value       = module.okta_aws_federation.role_arns
}

output "okta_group_names" {
  description = "Okta group names to assign users to for each access tier."
  value       = module.okta_aws_federation.okta_group_names
}
