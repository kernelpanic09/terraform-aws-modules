variable "name" {
  description = "Base name for all resources created by this module. Used as a prefix."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,38}[a-z0-9]$", var.name))
    error_message = "name must be 2-40 characters, start with a letter, end with a letter or digit, and contain only lowercase letters, digits, and hyphens."
  }
}

variable "organization" {
  description = "GitHub organization name. Used to scope runner registration."
  type        = string

  validation {
    condition     = length(var.organization) > 0
    error_message = "organization must not be empty."
  }
}

variable "repos" {
  description = "List of repository names (without the org prefix) to register runners for. When empty, runners are registered at the organization level."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for r in var.repos : can(regex("^[a-zA-Z0-9._-]+$", r))])
    error_message = "Each repo name must contain only alphanumeric characters, dots, underscores, and hyphens."
  }
}

variable "github_pat_secret_arn" {
  description = "ARN of the Secrets Manager secret that stores the GitHub Personal Access Token. The secret value must be a plain string containing the PAT. The PAT requires the 'admin:org' scope for org-level runners or 'repo' scope for repo-level runners."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+", var.github_pat_secret_arn))
    error_message = "github_pat_secret_arn must be a valid Secrets Manager ARN."
  }
}

variable "webhook_secret_arn" {
  description = "ARN of the Secrets Manager secret that stores the GitHub webhook secret string used for HMAC signature verification."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+", var.webhook_secret_arn))
    error_message = "webhook_secret_arn must be a valid Secrets Manager ARN."
  }
}

variable "vpc_id" {
  description = "VPC ID in which runner ECS tasks will run."
  type        = string

  validation {
    condition     = can(regex("^vpc-[a-f0-9]+$", var.vpc_id))
    error_message = "vpc_id must be a valid VPC ID (e.g., vpc-0abc123)."
  }
}

variable "subnet_ids" {
  description = "List of subnet IDs where runner ECS tasks will be placed. Private subnets with NAT Gateway access to the internet are recommended."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) > 0
    error_message = "At least one subnet ID must be provided."
  }

  validation {
    condition     = alltrue([for s in var.subnet_ids : can(regex("^subnet-[a-f0-9]+$", s))])
    error_message = "Each subnet_id must be a valid subnet ID (e.g., subnet-0abc123)."
  }
}

variable "runner_image" {
  description = "Docker image to use for the GitHub Actions runner container."
  type        = string
  default     = "myoung34/github-runner:latest"

  validation {
    condition     = length(var.runner_image) > 0
    error_message = "runner_image must not be empty."
  }
}

variable "runner_cpu" {
  description = "CPU units to allocate for each runner task (1024 = 1 vCPU). Valid Fargate values: 256, 512, 1024, 2048, 4096, 8192, 16384."
  type        = number
  default     = 1024

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096, 8192, 16384], var.runner_cpu)
    error_message = "runner_cpu must be one of the valid Fargate CPU values: 256, 512, 1024, 2048, 4096, 8192, 16384."
  }
}

variable "runner_memory" {
  description = "Memory (MiB) to allocate for each runner task. Must be compatible with the chosen runner_cpu per Fargate task size constraints."
  type        = number
  default     = 2048

  validation {
    condition     = var.runner_memory >= 512 && var.runner_memory <= 122880
    error_message = "runner_memory must be between 512 and 122880 MiB."
  }
}

variable "runner_labels" {
  description = "List of additional labels to apply to runners (beyond 'self-hosted' and 'linux' which are always included)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for l in var.runner_labels : can(regex("^[a-zA-Z0-9_.-]+$", l))])
    error_message = "Each runner label must contain only alphanumeric characters, underscores, dots, and hyphens."
  }
}

variable "runner_group" {
  description = "Runner group name in GitHub. Defaults to 'Default'."
  type        = string
  default     = "Default"

  validation {
    condition     = length(var.runner_group) > 0
    error_message = "runner_group must not be empty."
  }
}

variable "min_runners" {
  description = "Minimum number of runner tasks to keep running. Set to 0 to allow scale-to-zero when idle."
  type        = number
  default     = 0

  validation {
    condition     = var.min_runners >= 0
    error_message = "min_runners must be >= 0."
  }
}

variable "max_runners" {
  description = "Maximum number of concurrent runner tasks allowed."
  type        = number
  default     = 20

  validation {
    condition     = var.max_runners >= 1 && var.max_runners <= 200
    error_message = "max_runners must be between 1 and 200."
  }
}

variable "fargate_spot_weight" {
  description = "Weight for Fargate Spot capacity provider. Higher values mean more Spot tasks. Combined with fargate_ondemand_weight to determine the Spot/On-Demand ratio."
  type        = number
  default     = 7

  validation {
    condition     = var.fargate_spot_weight >= 0 && var.fargate_spot_weight <= 100
    error_message = "fargate_spot_weight must be between 0 and 100."
  }
}

variable "fargate_ondemand_weight" {
  description = "Weight for Fargate On-Demand capacity provider. Used as the baseline alongside fargate_spot_weight."
  type        = number
  default     = 3

  validation {
    condition     = var.fargate_ondemand_weight >= 0 && var.fargate_ondemand_weight <= 100
    error_message = "fargate_ondemand_weight must be between 0 and 100."
  }
}

variable "log_retention_days" {
  description = "Number of days to retain CloudWatch Logs for runners and Lambda."
  type        = number
  default     = 14

  validation {
    condition = contains(
      [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.log_retention_days
    )
    error_message = "log_retention_days must be a valid CloudWatch Logs retention value."
  }
}

variable "enable_dlq" {
  description = "When true, creates an SQS dead-letter queue to capture failed webhook Lambda invocations."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Map of tags to apply to all resources created by this module."
  type        = map(string)
  default     = {}
}
