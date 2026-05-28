##############################################################################
# Example: Multi-Account Identity Center Configuration
#
# This example models a realistic org structure:
#   - management account (billing, org-level)
#   - production account
#   - staging account
#   - sandbox account (dev experimentation)
#
# Groups:
#   - platform-admins: full admin across all accounts
#   - developers: full power-user in staging/sandbox, read-only in prod
#   - data-engineers: read S3/Glue/Athena in prod, full access in staging
#   - security-auditors: read-only everywhere, including management
#   - finops: billing read-only in management, read-only elsewhere
#
# Run from the management account (or delegated admin account for SSO).
##############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"

  # In production, use a backend and assume_role to the management account
  # assume_role {
  #   role_arn = "arn:aws:iam::948506259374:role/TerraformExecutionRole"
  # }
}

locals {
  # Centralize account IDs so they're easy to update
  accounts = {
    management = "948506259374"
    production = "111111111111"
    staging    = "222222222222"
    sandbox    = "333333333333"
  }
}

module "identity_center" {
  source = "../../modules/identity-center"

  ##############################################################################
  # Permission Sets
  ##############################################################################

  permission_sets = [
    # --- Admin ---
    {
      name             = "Administrator"
      description      = "Full administrative access. Short session for least-privilege."
      session_duration = "PT2H"
      managed_policy_arns = [
        "arn:aws:iam::aws:policy/AdministratorAccess",
      ]
    },

    # --- Developer ---
    # PowerUser minus IAM mutations, so developers can't elevate their own privileges
    {
      name             = "Developer"
      description      = "Power-user access minus IAM and billing mutations"
      session_duration = "PT8H"
      managed_policy_arns = [
        "arn:aws:iam::aws:policy/PowerUserAccess",
      ]
      inline_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid    = "DenyPrivilegeEscalation"
            Effect = "Deny"
            Action = [
              "iam:CreateUser",
              "iam:DeleteUser",
              "iam:AttachUserPolicy",
              "iam:DetachUserPolicy",
              "iam:PutUserPolicy",
              "iam:DeleteUserPolicy",
              "iam:CreateAccessKey",
              "iam:UpdateAccessKey",
            ]
            Resource = "*"
          },
        ]
      })
    },

    # --- Read-Only ---
    {
      name             = "ReadOnly"
      description      = "Read-only access to all AWS services"
      session_duration = "PT8H"
      managed_policy_arns = [
        "arn:aws:iam::aws:policy/ReadOnlyAccess",
      ]
    },

    # --- Data Engineer ---
    # Scoped to the data plane: S3, Glue, Athena, Lake Formation, Redshift Serverless
    {
      name             = "DataEngineer"
      description      = "Data platform access: S3, Glue, Athena, Lake Formation, Redshift Serverless"
      session_duration = "PT8H"
      managed_policy_arns = [
        "arn:aws:iam::aws:policy/AmazonS3FullAccess",
        "arn:aws:iam::aws:policy/AWSGlueConsoleFullAccess",
        "arn:aws:iam::aws:policy/AmazonAthenaFullAccess",
      ]
      inline_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid    = "LakeFormationRead"
            Effect = "Allow"
            Action = [
              "lakeformation:GetDataAccess",
              "lakeformation:DescribeResource",
              "lakeformation:ListPermissions",
            ]
            Resource = "*"
          },
        ]
      })
    },

    # --- Billing Read-Only ---
    # Used for FinOps team in the management account
    {
      name             = "BillingReadOnly"
      description      = "Read-only access to billing, Cost Explorer, and budgets"
      session_duration = "PT8H"
      managed_policy_arns = [
        "arn:aws:iam::aws:policy/AWSBillingReadOnlyAccess",
        "arn:aws:iam::aws:policy/ReadOnlyAccess",
      ]
    },
  ]

  ##############################################################################
  # Groups
  ##############################################################################

  groups = [
    {
      name        = "platform-admins"
      description = "Platform engineering team. Full admin across all accounts."
    },
    {
      name        = "developers"
      description = "Application developers. Power-user in staging/sandbox, read-only in prod."
    },
    {
      name        = "data-engineers"
      description = "Data platform team. Data-scoped access in staging, read-only in prod."
    },
    {
      name        = "security-auditors"
      description = "Security and compliance. Read-only everywhere including management."
    },
    {
      name        = "finops"
      description = "FinOps/Cloud economics. Billing read-only in management, read-only elsewhere."
    },
  ]

  ##############################################################################
  # Account Assignments
  #
  # Each entry is a group + permission set + list of account IDs.
  # The module flattens these into individual (group, permission_set, account)
  # triples -- each a separate aws_ssoadmin_account_assignment resource.
  ##############################################################################

  account_assignments = [
    # Platform admins: full admin across all accounts
    {
      group_name          = "platform-admins"
      permission_set_name = "Administrator"
      account_ids = [
        local.accounts.management,
        local.accounts.production,
        local.accounts.staging,
        local.accounts.sandbox,
      ]
    },

    # Developers: power-user in staging and sandbox
    {
      group_name          = "developers"
      permission_set_name = "Developer"
      account_ids = [
        local.accounts.staging,
        local.accounts.sandbox,
      ]
    },

    # Developers: read-only in production
    {
      group_name          = "developers"
      permission_set_name = "ReadOnly"
      account_ids = [
        local.accounts.production,
      ]
    },

    # Data engineers: full data-plane access in staging
    {
      group_name          = "data-engineers"
      permission_set_name = "DataEngineer"
      account_ids = [
        local.accounts.staging,
        local.accounts.sandbox,
      ]
    },

    # Data engineers: read-only in production (they can query but not modify)
    {
      group_name          = "data-engineers"
      permission_set_name = "ReadOnly"
      account_ids = [
        local.accounts.production,
      ]
    },

    # Security auditors: read-only everywhere
    {
      group_name          = "security-auditors"
      permission_set_name = "ReadOnly"
      account_ids = [
        local.accounts.management,
        local.accounts.production,
        local.accounts.staging,
        local.accounts.sandbox,
      ]
    },

    # FinOps: billing read-only in management account
    {
      group_name          = "finops"
      permission_set_name = "BillingReadOnly"
      account_ids = [
        local.accounts.management,
      ]
    },

    # FinOps: standard read-only in workload accounts for resource context
    {
      group_name          = "finops"
      permission_set_name = "ReadOnly"
      account_ids = [
        local.accounts.production,
        local.accounts.staging,
      ]
    },
  ]

  tags = {
    Environment = "management"
    ManagedBy   = "terraform"
    Team        = "platform"
  }
}

##############################################################################
# Outputs
##############################################################################

output "instance_arn" {
  description = "Identity Center instance ARN"
  value       = module.identity_center.instance_arn
}

output "identity_store_id" {
  description = "Identity Store ID"
  value       = module.identity_center.identity_store_id
}

output "permission_set_arns" {
  description = "Map of permission set name to ARN (useful for cross-module references)"
  value       = module.identity_center.permission_set_arns
}

output "group_ids" {
  description = "Map of group name to Identity Store group ID"
  value       = module.identity_center.group_ids
}
