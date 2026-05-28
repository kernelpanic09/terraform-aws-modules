# ---------------------------------------------------------------------------
# Example: 3-instance Aurora PostgreSQL cluster
#
# This deploys a writer + 2 readers with Performance Insights, Enhanced
# Monitoring, CloudWatch alarms, and Secrets Manager. Cross-region
# replication is commented out to avoid the extra cost. uncomment and
# fill in replica_subnet_ids to enable it.
#
# Run:
#   terraform init
#   terraform plan -var="alarm_email=ops@example.com"
#   terraform apply -var="alarm_email=ops@example.com"
# ---------------------------------------------------------------------------

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
  region = var.aws_region
}

# The module requires this alias even when cross-region replication is off.
# Point it at the same region when not replicating.
provider "aws" {
  alias  = "replica"
  region = var.aws_region

  # When enabling cross-region replication, change this to the replica region,
  # e.g. "eu-west-1", and supply that region's subnet IDs below.
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region for the primary cluster."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name used in resource names and tags."
  type        = string
  default     = "production"
}

variable "alarm_email" {
  description = "Email address to receive CloudWatch alarm notifications."
  type        = string
}

variable "kms_key_id" {
  description = "Optional KMS key ARN for encryption. Uses the default RDS key if empty."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# VPC (using the community VPC module)
# ---------------------------------------------------------------------------

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "aurora-example-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}b", "${var.aws_region}c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  # NAT gateway lets the Lambda rotation function reach Secrets Manager.
  enable_nat_gateway = true
  single_nat_gateway = true

  # DNS hostnames are needed for RDS endpoint resolution.
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Locals
# ---------------------------------------------------------------------------

locals {
  cluster_name = "myapp-${var.environment}"

  common_tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Project     = "aurora-example"
  }
}

# ---------------------------------------------------------------------------
# Aurora cluster
# ---------------------------------------------------------------------------

module "aurora" {
  source = "../module"

  providers = {
    aws         = aws
    aws.replica = aws.replica
  }

  name           = local.cluster_name
  engine         = "aurora-postgresql"
  engine_version = "15.4"

  # 1 writer + 2 readers.
  instance_class = "db.r6g.large"
  instance_count = 3

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Allow connections only from within the VPC private subnets.
  # Replace with your application security group ID once it exists.
  allowed_cidr_blocks = module.vpc.private_subnets_cidr_blocks

  database_name   = "myapp"
  master_username = "dbadmin"
  # master_password intentionally omitted. the module generates one and
  # stores it in Secrets Manager.

  kms_key_id = var.kms_key_id

  enable_iam_auth = true

  # Backup: 7 days, 2-3 AM UTC, maintenance Sunday 5-6 AM UTC.
  backup_retention_days        = 7
  preferred_backup_window      = "02:00-03:00"
  preferred_maintenance_window = "sun:05:00-sun:06:00"

  deletion_protection = true
  skip_final_snapshot = false

  # Performance Insights with 7-day free retention.
  enable_performance_insights         = true
  performance_insights_retention_days = 7

  # Enhanced Monitoring at 60-second granularity.
  enable_enhanced_monitoring = true
  monitoring_interval        = 60

  # Secrets Manager stores the generated password.
  # Rotation is off for now. enable once you deploy the SAR rotator Lambda.
  enable_secrets_manager = true
  enable_rotation        = false

  # Alarm notifications.
  alarm_emails = [var.alarm_email]

  # Override slow-query threshold to 500 ms for this app.
  cluster_parameters = {
    log_min_duration_statement = {
      value        = "500"
      apply_method = "immediate"
    }
  }

  # ---------------------------------------------------------------------------
  # Cross-region replication (disabled to save cost)
  #
  # To enable:
  #   1. Change `enable_cross_region_replica` to true.
  #   2. Set `replica_region` to your target region.
  #   3. Provide `replica_subnet_ids` for that region.
  #   4. Update the `aws.replica` provider block to use the target region.
  #   5. If using a custom KMS key, create one in the replica region too.
  # ---------------------------------------------------------------------------
  enable_cross_region_replica = false
  # replica_region         = "eu-west-1"
  # replica_subnet_ids     = ["subnet-aaaa", "subnet-bbbb", "subnet-cccc"]
  # replica_instance_count = 1
  # replica_instance_class = "db.r6g.large"

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "cluster_writer_endpoint" {
  description = "Writer endpoint. Point your application's primary DB connection here."
  value       = module.aurora.cluster_endpoint
}

output "cluster_reader_endpoint" {
  description = "Reader endpoint. Use this for read-heavy queries."
  value       = module.aurora.cluster_reader_endpoint
}

output "cluster_port" {
  description = "PostgreSQL port."
  value       = module.aurora.cluster_port
}

output "cluster_database_name" {
  value = module.aurora.cluster_database_name
}

output "cluster_master_username" {
  value = module.aurora.cluster_master_username
}

output "secret_arn" {
  description = "Retrieve the master password from this secret: aws secretsmanager get-secret-value --secret-id <arn>"
  value       = module.aurora.secret_arn
}

output "security_group_id" {
  description = "Add this SG as an allowed_security_group_ids source for other modules."
  value       = module.aurora.security_group_id
}

output "sns_topic_arn" {
  description = "SNS topic receiving CloudWatch alarms."
  value       = module.aurora.sns_topic_arn
}

output "enhanced_monitoring_role_arn" {
  value = module.aurora.enhanced_monitoring_role_arn
}
