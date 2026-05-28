###############################################################################
# Example: GitHub Actions OIDC role setup
#
# This example creates an IAM role that GitHub Actions workflows can assume
# via OIDC (no long-lived credentials required). The role is scoped to a
# specific repository and branch, with ECR and ECS permissions for a typical
# container delivery pipeline.
#
# Usage:
#   terraform init
#   terraform apply -var="aws_account_id=$(aws sts get-caller-identity --query Account --output text)"
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
  }

  # After bootstrapping with the landing-zone module, switch to remote state:
  # backend "s3" {
  #   bucket         = "myorg-terraform-state-123456789012"
  #   key            = "iam/github-oidc/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "myorg-terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region
}

###############################################################################
# Variables
###############################################################################

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "aws_account_id" {
  description = "Target AWS account ID (used to construct resource ARNs)."
  type        = string
}

variable "github_org" {
  description = "GitHub organization or username."
  type        = string
  default     = "my-github-org"
}

variable "github_repo" {
  description = "GitHub repository name (without org prefix)."
  type        = string
  default     = "my-app"
}

variable "environment" {
  description = "Deployment environment label (e.g., production, staging)."
  type        = string
  default     = "production"
}

###############################################################################
# Permissions boundary (optional but recommended)
#
# Caps what the CI/CD role can ever do even if the role's policies are broadened
# later. Deployed as a standalone policy so it can be reused by other modules.
###############################################################################

resource "aws_iam_policy" "cicd_boundary" {
  name        = "cicd-permissions-boundary"
  description = "Permissions boundary that caps CI/CD roles to ECR, ECS, S3, and CloudWatch actions."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCICDServices"
        Effect = "Allow"
        Action = [
          "ecr:*",
          "ecs:*",
          "s3:Get*",
          "s3:List*",
          "s3:Put*",
          "s3:Delete*",
          "cloudwatch:*",
          "logs:*",
          "ssm:GetParameter*",
        ]
        Resource = "*"
      },
      {
        Sid    = "DenyIAMEscalation"
        Effect = "Deny"
        Action = [
          "iam:CreateUser",
          "iam:CreateRole",
          "iam:AttachRolePolicy",
          "iam:PutRolePolicy",
          "iam:UpdateAssumeRolePolicy",
          "organizations:*",
        ]
        Resource = "*"
      }
    ]
  })

  tags = local.tags
}

###############################################################################
# IAM roles module
###############################################################################

locals {
  tags = {
    Environment = var.environment
    GithubOrg   = var.github_org
    GithubRepo  = var.github_repo
    ManagedBy   = "terraform"
  }
}

module "iam_roles" {
  source = "../../modules/iam-roles"

  name_prefix = "myorg"

  # Only create the CI/CD role in this example
  create_admin_role     = false
  create_readonly_role  = false
  create_developer_role = false
  create_cicd_role      = true

  # GitHub OIDC configuration
  # Scoped to main branch only - adjust for your branching strategy
  github_org          = var.github_org
  github_repositories = [var.github_repo]
  github_branches     = ["ref:refs/heads/main"]

  # Create the OIDC provider (set to false if it already exists in this account)
  create_github_oidc_provider = true

  # Attach policies for a container delivery pipeline
  cicd_extra_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonECR_FullAccess",
    "arn:aws:iam::aws:policy/AmazonECS_FullAccess",
  ]

  # Apply the boundary so the CI/CD role can never exceed these permissions
  cicd_permissions_boundary_arn = aws_iam_policy.cicd_boundary.arn

  cicd_session_duration = 3600

  tags = local.tags
}

###############################################################################
# Outputs
###############################################################################

output "cicd_role_arn" {
  description = "ARN to use in the GitHub Actions workflow: permissions.id-token: write + aws-actions/configure-aws-credentials."
  value       = module.iam_roles.cicd_role_arn
}

output "github_oidc_provider_arn" {
  description = "ARN of the GitHub OIDC identity provider created in this account."
  value       = module.iam_roles.github_oidc_provider_arn
}

output "workflow_snippet" {
  description = "Paste this into your GitHub Actions workflow YAML under 'jobs.<job>.steps'. Replace GITHUB_RUN_ID with the GitHub Actions expression for github.run_id."
  value       = <<-EOT
    permissions:
      id-token: write
      contents: read

    steps:
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${module.iam_roles.cicd_role_arn}
          aws-region: ${var.aws_region}
          role-session-name: GitHubActions-GITHUB_RUN_ID
  EOT
}
