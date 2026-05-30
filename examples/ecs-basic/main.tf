###############################################################################
# Example: VPC + ECS Fargate (basic)
#
# Provisions a three-AZ VPC with NAT Gateways and deploys a containerized
# application behind an Application Load Balancer using the ecs-fargate module.
# Autoscaling is enabled to demonstrate CPU-based target tracking.
#
# Usage:
#   export AWS_REGION=us-east-1
#   terraform init
#   terraform plan
#   terraform apply
###############################################################################

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = var.environment
      Project     = var.project
      ManagedBy   = "terraform"
    }
  }
}

# ------------------------------------------------------------------------------
# Variables
# ------------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (e.g., staging, production)."
  type        = string
  default     = "staging"
}

variable "project" {
  description = "Project name applied to all resource tags."
  type        = string
  default     = "platform"
}

variable "app_name" {
  description = "Short application name used as the resource prefix."
  type        = string
  default     = "api"
}

variable "container_image" {
  description = "Container image URI. Override with your ECR image on apply."
  type        = string
  default     = "public.ecr.aws/nginx/nginx:1.27-alpine"
}

variable "container_port" {
  description = "Port the container listens on."
  type        = number
  default     = 80
}

# ------------------------------------------------------------------------------
# VPC
# ------------------------------------------------------------------------------

module "vpc" {
  source = "../../modules/vpc"

  name               = var.app_name
  vpc_cidr           = "10.0.0.0/16"
  az_count           = 3
  single_nat_gateway = true # Single NAT for cost savings in non-prod.
  enable_flow_logs   = true

  tags = {
    Environment = var.environment
    Project     = var.project
  }
}

# ------------------------------------------------------------------------------
# ECS Fargate
# ------------------------------------------------------------------------------

module "ecs" {
  source = "../../modules/ecs-fargate"

  name              = var.app_name
  vpc_id            = module.vpc.vpc_id
  subnet_ids        = module.vpc.private_subnet_ids
  public_subnet_ids = module.vpc.public_subnet_ids

  # Container
  container_image = var.container_image
  container_port  = var.container_port
  cpu             = 256
  memory          = 512

  # Plain-text environment variables
  environment_variables = {
    APP_ENV   = var.environment
    LOG_LEVEL = "info"
    PORT      = tostring(var.container_port)
  }

  # Secrets: reference SSM parameters that must exist before apply.
  # Uncomment and adjust ARNs once parameters are created.
  # ssm_secrets = {
  #   DATABASE_URL = "arn:aws:ssm:${var.aws_region}:ACCOUNT_ID:parameter/${var.app_name}/${var.environment}/database_url"
  #   JWT_SECRET   = "arn:aws:ssm:${var.aws_region}:ACCOUNT_ID:parameter/${var.app_name}/${var.environment}/jwt_secret"
  # }

  # Service
  desired_count = 2

  # Health check: nginx serves /index.html, not /health. In a real service
  # implement a /health endpoint and update this path.
  health_check_path    = "/"
  health_check_matcher = "200"

  # HTTPS: set enable_https = true and provide a valid certificate_arn.
  enable_https    = false
  certificate_arn = ""

  # Autoscaling: scale between 2 and 10 tasks, target 70% CPU.
  enable_autoscaling     = true
  min_count              = 2
  max_count              = 10
  autoscaling_cpu_target = 70
  scale_in_cooldown      = 300
  scale_out_cooldown     = 60

  # Logging
  log_retention_days = 14

  tags = {
    Environment = var.environment
    Project     = var.project
  }
}

# ------------------------------------------------------------------------------
# Outputs
# ------------------------------------------------------------------------------

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer. Point your CNAME or alias record here."
  value       = module.ecs.alb_dns_name
}

output "alb_zone_id" {
  description = "Route53 hosted zone ID of the ALB. Use with alias records."
  value       = module.ecs.alb_zone_id
}

output "cluster_name" {
  description = "ECS cluster name."
  value       = module.ecs.cluster_name
}

output "service_name" {
  description = "ECS service name."
  value       = module.ecs.service_name
}

output "task_role_arn" {
  description = "ARN of the task IAM role. Attach application-specific policies here."
  value       = module.ecs.task_role_arn
}

output "tasks_security_group_id" {
  description = "ECS tasks security group ID. Reference in downstream resource security groups (RDS, ElastiCache)."
  value       = module.ecs.tasks_security_group_id
}

output "log_group_name" {
  description = "CloudWatch Log Group name for container logs."
  value       = module.ecs.log_group_name
}

output "vpc_id" {
  description = "VPC ID."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (ECS tasks)."
  value       = module.vpc.private_subnet_ids
}

output "nat_gateway_ips" {
  description = "Public IPs of NAT Gateways. Allowlist these in external APIs or firewall rules."
  value       = module.vpc.nat_gateway_ips
}
