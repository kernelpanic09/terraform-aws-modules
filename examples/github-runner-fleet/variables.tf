variable "aws_region" {
  description = "AWS region to deploy the runner fleet into."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]+$", var.aws_region))
    error_message = "aws_region must be a valid AWS region (e.g., us-east-1)."
  }
}

variable "name" {
  description = "Base name used as a prefix for all resources. Should be short and identifying."
  type        = string
  default     = "gh-runners"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,38}[a-z0-9]$", var.name))
    error_message = "name must be 2-40 characters, lowercase alphanumeric and hyphens, starting with a letter."
  }
}

variable "environment" {
  description = "Environment name applied to all resource tags (e.g., production, staging)."
  type        = string
  default     = "production"

  validation {
    condition     = contains(["production", "staging", "development"], var.environment)
    error_message = "environment must be one of: production, staging, development."
  }
}

variable "owner" {
  description = "Team or individual owner tag value applied to all resources."
  type        = string
  default     = "platform"
}

# ---------------------------------------------------------------------------
# GitHub
# ---------------------------------------------------------------------------

variable "github_org" {
  description = "GitHub organization name for runner registration."
  type        = string

  validation {
    condition     = length(var.github_org) > 0
    error_message = "github_org must not be empty."
  }
}

variable "github_repos" {
  description = "Optional list of repository names to register runners for. Empty list = org-level runners."
  type        = list(string)
  default     = []
}

variable "github_pat" {
  description = "GitHub Personal Access Token with admin:org scope (org runners) or repo scope (repo runners). Set via TF_VAR_github_pat environment variable."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.github_pat) > 10
    error_message = "github_pat must be a valid GitHub PAT (ghp_... or github_pat_...)."
  }
}

variable "webhook_secret" {
  description = "Random secret string used to verify GitHub webhook HMAC signatures. Use `openssl rand -hex 32` to generate. Set via TF_VAR_webhook_secret."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.webhook_secret) >= 16
    error_message = "webhook_secret must be at least 16 characters."
  }
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.100.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid CIDR block."
  }
}

variable "availability_zones" {
  description = "List of AZs to deploy subnets into. Should match your target region."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "At least 2 availability zones are required for high availability."
  }
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ). Runner tasks run here."
  type        = list(string)
  default     = ["10.100.1.0/24", "10.100.2.0/24", "10.100.3.0/24"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ). NAT Gateways are placed here."
  type        = list(string)
  default     = ["10.100.101.0/24", "10.100.102.0/24", "10.100.103.0/24"]
}

# ---------------------------------------------------------------------------
# Runner configuration
# ---------------------------------------------------------------------------

variable "runner_image" {
  description = "Docker image for the GitHub Actions runner."
  type        = string
  default     = "myoung34/github-runner:latest"
}

variable "runner_cpu" {
  description = "CPU units per runner task (1024 = 1 vCPU)."
  type        = number
  default     = 1024

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096, 8192, 16384], var.runner_cpu)
    error_message = "runner_cpu must be a valid Fargate CPU value."
  }
}

variable "runner_memory" {
  description = "Memory (MiB) per runner task."
  type        = number
  default     = 2048

  validation {
    condition     = var.runner_memory >= 512 && var.runner_memory <= 122880
    error_message = "runner_memory must be between 512 and 122880 MiB."
  }
}

variable "runner_labels" {
  description = "Additional runner labels beyond 'self-hosted' and 'linux'."
  type        = list(string)
  default     = ["fargate", "aws"]
}

variable "runner_group" {
  description = "GitHub runner group to register runners into."
  type        = string
  default     = "Default"
}

variable "min_runners" {
  description = "Minimum number of idle runner tasks (0 = scale to zero)."
  type        = number
  default     = 0
}

variable "max_runners" {
  description = "Maximum number of concurrent runner tasks."
  type        = number
  default     = 20

  validation {
    condition     = var.max_runners >= 1 && var.max_runners <= 200
    error_message = "max_runners must be between 1 and 200."
  }
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------

variable "log_retention_days" {
  description = "Days to retain CloudWatch Logs."
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
