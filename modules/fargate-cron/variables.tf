# ---------------------------------------------------------------------------
# Core
# ---------------------------------------------------------------------------

variable "name" {
  description = "Name prefix for all resources created by this module."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]{1,64}$", var.name))
    error_message = "name must be 1-64 characters and contain only letters, numbers, and hyphens."
  }
}

variable "cluster_arn" {
  description = <<-EOT
    ARN of an existing ECS cluster to run tasks on. This module does NOT create
    a cluster. Reuse the one from your ecs-fargate module or create a dedicated
    cron cluster externally and pass its ARN here.
  EOT
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:ecs:[a-z0-9-]+:[0-9]{12}:cluster/.+$", var.cluster_arn))
    error_message = "cluster_arn must be a valid ECS cluster ARN."
  }
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Container
# ---------------------------------------------------------------------------

variable "container_image" {
  description = "Docker image to run, including tag. e.g. 123456789012.dkr.ecr.us-east-1.amazonaws.com/my-job:latest"
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9._/:@-]+$", var.container_image))
    error_message = "container_image must be a valid Docker image reference."
  }
}

variable "container_command" {
  description = "Optional command override for the container. Overrides the image CMD. Leave empty to use the image default."
  type        = list(string)
  default     = []
}

variable "cpu" {
  description = <<-EOT
    CPU units for the Fargate task. Valid Fargate values: 256, 512, 1024, 2048, 4096, 8192, 16384.
    Note: 8192 and 16384 require at least 16384 MB memory.
  EOT
  type        = number
  default     = 256

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096, 8192, 16384], var.cpu)
    error_message = "cpu must be a valid Fargate value: 256, 512, 1024, 2048, 4096, 8192, or 16384."
  }
}

variable "memory" {
  description = <<-EOT
    Memory in MiB for the Fargate task. Must be compatible with the cpu value:
      256  CPU  -> 512-2048 (in 512 increments)
      512  CPU  -> 1024-4096 (in 1024 increments)
      1024 CPU  -> 2048-8192 (in 1024 increments)
      2048 CPU  -> 4096-16384 (in 1024 increments)
      4096 CPU  -> 8192-30720 (in 1024 increments)
      8192 CPU  -> 16384-61440 (in 4096 increments)
      16384 CPU -> 32768-122880 (in 8192 increments)
  EOT
  type        = number
  default     = 512

  validation {
    condition     = var.memory >= 512 && var.memory <= 122880
    error_message = "memory must be between 512 and 122880 MiB. Exact constraints depend on cpu value - Fargate will reject incompatible combinations at apply time."
  }
}

variable "environment_variables" {
  description = "Plain-text environment variables passed to the container."
  type        = map(string)
  default     = {}
}

variable "ssm_secrets" {
  description = <<-EOT
    Map of environment variable name to SSM Parameter ARN. Values are injected
    as secrets via the ECS secrets mechanism - they never appear in task
    definition logs. The execution role gets ssm:GetParameters for each ARN.
    Example: { DATABASE_URL = "arn:aws:ssm:us-east-1:123456789012:parameter/myapp/db-url" }
  EOT
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Schedule
# ---------------------------------------------------------------------------

variable "schedule_expression" {
  description = <<-EOT
    EventBridge schedule expression. Supports cron and rate formats:
      cron(0 2 * * ? *)  - 2am UTC daily (note: EventBridge uses ? for day-of-week/day-of-month wildcard)
      rate(1 hour)       - every hour
      rate(7 days)       - every 7 days
  EOT
  type        = string

  validation {
    condition     = can(regex("^(cron|rate)\\(.+\\)$", var.schedule_expression))
    error_message = "schedule_expression must be in cron(...) or rate(...) format."
  }
}

variable "max_retry_attempts" {
  description = "Number of times EventBridge retries a failed invocation. 0 means no retries."
  type        = number
  default     = 0

  validation {
    condition     = var.max_retry_attempts >= 0 && var.max_retry_attempts <= 185
    error_message = "max_retry_attempts must be between 0 and 185."
  }
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

variable "vpc_id" {
  description = "VPC ID where the security group is created."
  type        = string

  validation {
    condition     = can(regex("^vpc-[a-f0-9]+$", var.vpc_id))
    error_message = "vpc_id must be a valid VPC ID (e.g. vpc-0abc123def456789)."
  }
}

variable "subnet_ids" {
  description = "List of subnet IDs where the Fargate task runs. Private subnets with a NAT gateway are recommended. Public IP is disabled."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 1
    error_message = "At least one subnet ID is required."
  }
}

variable "additional_egress_rules" {
  description = <<-EOT
    Extra egress rules to add to the task security group. The module always
    allows all outbound traffic (0.0.0.0/0) as the default. Use this to
    restrict egress or add additional rules if needed.
    Each object: { description, from_port, to_port, protocol, cidr_blocks, ipv6_cidr_blocks (optional) }
  EOT
  type = list(object({
    description      = string
    from_port        = number
    to_port          = number
    protocol         = string
    cidr_blocks      = list(string)
    ipv6_cidr_blocks = optional(list(string), [])
  }))
  default = []
}

# ---------------------------------------------------------------------------
# IAM
# ---------------------------------------------------------------------------

variable "task_role_policy_arns" {
  description = "List of IAM policy ARNs to attach to the task role. This is how you grant the container permissions to call AWS services."
  type        = list(string)
  default     = []
}

variable "execution_role_policy_arns" {
  description = "Additional IAM policy ARNs to attach to the execution role. The module already attaches AmazonECSTaskExecutionRolePolicy plus SSM and CloudWatch permissions."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch log group retention in days. Valid values: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653, or 0 (never expire)."
  type        = number
  default     = 30

  validation {
    condition = contains(
      [0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.log_retention_days
    )
    error_message = "log_retention_days must be a valid CloudWatch retention value."
  }
}

# ---------------------------------------------------------------------------
# Dead letter queue
# ---------------------------------------------------------------------------

variable "enable_dlq" {
  description = "Create an SQS dead letter queue to capture EventBridge invocation failures."
  type        = bool
  default     = false
}

variable "dlq_message_retention_seconds" {
  description = "How long SQS retains DLQ messages. Defaults to 7 days."
  type        = number
  default     = 604800

  validation {
    condition     = var.dlq_message_retention_seconds >= 60 && var.dlq_message_retention_seconds <= 1209600
    error_message = "dlq_message_retention_seconds must be between 60 (1 minute) and 1209600 (14 days)."
  }
}

# ---------------------------------------------------------------------------
# Failure notifications
# ---------------------------------------------------------------------------

variable "enable_failure_notifications" {
  description = <<-EOT
    Subscribe to ECS task state change events and send an SNS notification when
    a task stops with a non-zero exit code. Creates an SNS topic, an
    EventBridge rule filtering for STOPPED tasks, and email subscriptions.
  EOT
  type        = bool
  default     = false
}

variable "notification_emails" {
  description = "Email addresses to notify on task failure. Only used when enable_failure_notifications is true."
  type        = list(string)
  default     = []
}
