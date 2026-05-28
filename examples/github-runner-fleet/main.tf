###############################################################################
# Example: Organization-level GitHub Actions runner fleet
#
# This example provisions:
#   - A VPC with private subnets (runners never need inbound traffic)
#   - Secrets Manager secrets for the GitHub PAT and webhook secret
#   - The github-runner-fleet module (ECS Fargate, Lambda, API Gateway)
#
# Prerequisites before applying:
#   1. Set TF_VAR_github_pat to a GitHub PAT with admin:org scope
#   2. Set TF_VAR_webhook_secret to a random string (>= 32 chars recommended)
#      Generate with: openssl rand -hex 32
#   3. After apply, configure the webhook in GitHub:
#      Organization -> Settings -> Webhooks -> Add webhook
#        Payload URL : <webhook_url output>
#        Content type: application/json
#        Secret      : <same value as TF_VAR_webhook_secret>
#        Events      : "Workflow jobs" (workflow_job)
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0"
    }
  }

  # Replace with your own state backend
  # backend "s3" {
  #   bucket  = "my-tf-state"
  #   key     = "github-runners/terraform.tfstate"
  #   region  = "us-east-1"
  #   encrypt = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "github-runner-fleet"
      Environment = var.environment
      Owner       = var.owner
      ManagedBy   = "terraform"
    }
  }
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.name}-vpc"
  cidr = var.vpc_cidr

  azs             = var.availability_zones
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  # NAT Gateway so private-subnet runners can reach GitHub and package registries
  enable_nat_gateway     = true
  single_nat_gateway     = var.environment != "production"
  one_nat_gateway_per_az = var.environment == "production"

  # DNS required for ECS task registration and Secrets Manager endpoint resolution
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name}-vpc"
  }
}

# ---------------------------------------------------------------------------
# Secrets Manager - GitHub PAT
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "github_pat" {
  name                    = "${var.name}/github-pat"
  description             = "GitHub Personal Access Token for ${var.github_org} runner registration"
  recovery_window_in_days = 7

  tags = {
    Name = "${var.name}-github-pat"
  }
}

resource "aws_secretsmanager_secret_version" "github_pat" {
  secret_id     = aws_secretsmanager_secret.github_pat.id
  secret_string = var.github_pat

  # Prevent the PAT value from appearing in Terraform plan output
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ---------------------------------------------------------------------------
# Secrets Manager - Webhook secret
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "webhook_secret" {
  name                    = "${var.name}/webhook-secret"
  description             = "HMAC secret for GitHub webhook signature verification"
  recovery_window_in_days = 7

  tags = {
    Name = "${var.name}-webhook-secret"
  }
}

resource "aws_secretsmanager_secret_version" "webhook_secret" {
  secret_id     = aws_secretsmanager_secret.webhook_secret.id
  secret_string = var.webhook_secret

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ---------------------------------------------------------------------------
# GitHub Runner Fleet module
# ---------------------------------------------------------------------------

module "runner_fleet" {
  source = "../module"

  name         = var.name
  organization = var.github_org
  repos        = var.github_repos

  github_pat_secret_arn = aws_secretsmanager_secret.github_pat.arn
  webhook_secret_arn    = aws_secretsmanager_secret.webhook_secret.arn

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Runner container configuration
  runner_image  = var.runner_image
  runner_cpu    = var.runner_cpu
  runner_memory = var.runner_memory
  runner_labels = var.runner_labels
  runner_group  = var.runner_group

  # Scaling
  min_runners = var.min_runners
  max_runners = var.max_runners

  # Capacity mix: 70% Spot, 30% On-Demand
  fargate_spot_weight     = 7
  fargate_ondemand_weight = 3

  # Observability
  log_retention_days = var.log_retention_days
  enable_dlq         = true

  tags = {
    Environment = var.environment
    Owner       = var.owner
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "webhook_url" {
  description = "Configure this URL as the GitHub organization webhook endpoint."
  value       = module.runner_fleet.webhook_url
}

output "ecs_cluster_name" {
  value = module.runner_fleet.ecs_cluster_name
}

output "ecs_service_name" {
  value = module.runner_fleet.ecs_service_name
}

output "runner_log_group" {
  value = module.runner_fleet.runner_log_group_name
}

output "dlq_url" {
  description = "Monitor this queue for failed webhook deliveries."
  value       = module.runner_fleet.dlq_url
}

output "ecs_task_role_arn" {
  description = "Attach additional IAM policies to this role to grant runners AWS access."
  value       = module.runner_fleet.ecs_task_role_arn
}
