terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# ---------------------------------------------------------------------------
# Data sources - pull in existing infrastructure
# ---------------------------------------------------------------------------

# The ECS cluster was created by the ecs-fargate module. We reuse it here
# rather than spinning up a second cluster just for cron jobs.
data "aws_ecs_cluster" "shared" {
  cluster_name = "my-app-cluster"
}

data "aws_vpc" "main" {
  tags = { Name = "main" }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  tags = { Tier = "private" }
}

# SSM parameter holding the database connection string.
data "aws_ssm_parameter" "database_url" {
  name = "/myapp/production/database-url"
}

# An IAM policy that allows the backup job to write to S3.
data "aws_iam_policy" "backup_s3" {
  name = "myapp-backup-s3-write"
}

# ---------------------------------------------------------------------------
# Nightly database backup job
# ---------------------------------------------------------------------------
#
# Runs at 2am UTC every day. The container is expected to exit 0 on success
# and non-zero on failure. If it fails, an email goes out to the on-call list
# and the event lands in the DLQ for manual inspection.
#

module "nightly_backup" {
  source = "../../modules/fargate-cron"

  name        = "nightly-db-backup"
  cluster_arn = data.aws_ecs_cluster.shared.arn

  # Container
  container_image   = "123456789012.dkr.ecr.us-east-1.amazonaws.com/db-backup:latest"
  container_command = ["/scripts/backup.sh", "--full"]
  cpu               = 512
  memory            = 1024

  # Plain env vars
  environment_variables = {
    S3_BUCKET      = "myapp-backups-prod"
    BACKUP_PREFIX  = "nightly"
    RETENTION_DAYS = "30"
  }

  # Secrets pulled from SSM at task launch time - never visible in the task
  # definition or CloudWatch logs.
  ssm_secrets = {
    DATABASE_URL = data.aws_ssm_parameter.database_url.arn
  }

  # 2am UTC every day.
  # EventBridge cron uses a 6-field format: min hour dom month dow year
  # The ? means "no specific value" - required when you specify the other of dom/dow.
  schedule_expression = "cron(0 2 * * ? *)"

  # Don't retry on failure - if the backup script failed we want to know
  # immediately rather than running it multiple times and potentially
  # corrupting a partial backup.
  max_retry_attempts = 0

  # Networking
  vpc_id     = data.aws_vpc.main.id
  subnet_ids = data.aws_subnets.private.ids

  # Application permissions: write to S3 for backup storage
  task_role_policy_arns = [data.aws_iam_policy.backup_s3.arn]

  # Logging
  log_retention_days = 30

  # DLQ - captures failed EventBridge invocations (e.g. if ECS is unavailable).
  # These are EventBridge-level failures, not task-level failures.
  enable_dlq                    = true
  dlq_message_retention_seconds = 604800 # 7 days

  # Failure notifications - fires when the container exits non-zero.
  enable_failure_notifications = true
  notification_emails = [
    "oncall@example.com",
    "devops-alerts@example.com",
  ]

  tags = {
    Environment = "production"
    Team        = "platform"
    ManagedBy   = "terraform"
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "backup_task_definition_arn" {
  description = "Current task definition ARN for the backup job."
  value       = module.nightly_backup.task_definition_arn
}

output "backup_log_group" {
  description = "CloudWatch log group - useful for grabbing logs after a run."
  value       = module.nightly_backup.log_group_name
}

output "backup_dlq_url" {
  description = "SQS DLQ URL to check for missed invocations."
  value       = module.nightly_backup.dlq_url
}

output "backup_failure_sns_arn" {
  description = "SNS topic ARN for task failure alerts."
  value       = module.nightly_backup.failure_sns_topic_arn
}
