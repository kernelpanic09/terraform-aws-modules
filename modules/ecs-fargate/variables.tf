# ------------------------------------------------------------------------------
# Core identity
# ------------------------------------------------------------------------------

variable "name" {
  description = "Name prefix applied to all resources created by this module. Must be lowercase alphanumeric with hyphens only."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.name)) && length(var.name) >= 1 && length(var.name) <= 32
    error_message = "Name must be 1-32 characters, lowercase alphanumeric and hyphens only."
  }
}

# ------------------------------------------------------------------------------
# Networking
# ------------------------------------------------------------------------------

variable "vpc_id" {
  description = "ID of the VPC where all resources will be created."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must be a valid VPC ID (e.g., vpc-0abc1234)."
  }
}

variable "subnet_ids" {
  description = "List of private subnet IDs for ECS task ENIs. Tasks run here; they reach the internet via NAT Gateway."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 1
    error_message = "At least one private subnet ID is required."
  }
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs for the Application Load Balancer. Must span at least two AZs."
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "ALB requires at least two public subnets in different Availability Zones."
  }
}

# ------------------------------------------------------------------------------
# Container
# ------------------------------------------------------------------------------

variable "container_image" {
  description = "Full container image URI including tag (e.g., 123456789.dkr.ecr.us-east-1.amazonaws.com/my-app:1.2.3)."
  type        = string

  validation {
    condition     = length(var.container_image) > 0
    error_message = "container_image must not be empty."
  }
}

variable "container_port" {
  description = "TCP port that the container listens on. Must match the port your application binds to."
  type        = number
  default     = 8080

  validation {
    condition     = var.container_port >= 1 && var.container_port <= 65535
    error_message = "container_port must be between 1 and 65535."
  }
}

variable "container_name" {
  description = "Name of the container definition inside the task definition. Defaults to var.name when null."
  type        = string
  default     = null
}

variable "cpu" {
  description = "Fargate task CPU units. Valid values: 256, 512, 1024, 2048, 4096, 8192, 16384. Memory allocation must be compatible with the chosen CPU value."
  type        = number
  default     = 512

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096, 8192, 16384], var.cpu)
    error_message = "cpu must be one of: 256, 512, 1024, 2048, 4096, 8192, 16384."
  }
}

variable "memory" {
  description = "Fargate task memory in MiB. Must be compatible with var.cpu. See https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_definition_parameters.html#task_size."
  type        = number
  default     = 1024

  validation {
    condition     = var.memory >= 512 && var.memory <= 122880
    error_message = "memory must be between 512 MiB and 122880 MiB."
  }
}

variable "environment_variables" {
  description = "Map of plain-text environment variables injected into the container. Do not place secrets here; use ssm_secrets instead."
  type        = map(string)
  default     = {}
}

variable "ssm_secrets" {
  description = "Map of environment variable names to SSM Parameter Store parameter ARNs. The task execution role is granted ssm:GetParameters and ssm:GetParameter for each ARN specified here."
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for arn in values(var.ssm_secrets) :
      can(regex("^arn:aws:ssm:", arn))
    ])
    error_message = "All values in ssm_secrets must be valid SSM Parameter Store ARNs (arn:aws:ssm:...)."
  }
}

# ------------------------------------------------------------------------------
# Service
# ------------------------------------------------------------------------------

variable "desired_count" {
  description = "Desired number of running task instances. When autoscaling is enabled this becomes the initial count."
  type        = number
  default     = 2

  validation {
    condition     = var.desired_count >= 0
    error_message = "desired_count must be >= 0."
  }
}

variable "deployment_minimum_healthy_percent" {
  description = "Lower bound on the number of tasks that must remain healthy during a rolling deployment, expressed as a percentage of desired_count."
  type        = number
  default     = 100

  validation {
    condition     = var.deployment_minimum_healthy_percent >= 0 && var.deployment_minimum_healthy_percent <= 100
    error_message = "deployment_minimum_healthy_percent must be 0-100."
  }
}

variable "deployment_maximum_percent" {
  description = "Upper bound on the number of tasks that may run during a rolling deployment, expressed as a percentage of desired_count."
  type        = number
  default     = 200

  validation {
    condition     = var.deployment_maximum_percent >= 100 && var.deployment_maximum_percent <= 200
    error_message = "deployment_maximum_percent must be 100-200."
  }
}

# ------------------------------------------------------------------------------
# Health check
# ------------------------------------------------------------------------------

variable "health_check_path" {
  description = "HTTP path used by the ALB target group health check. Must return a 2xx status code when healthy."
  type        = string
  default     = "/health"

  validation {
    condition     = can(regex("^/", var.health_check_path))
    error_message = "health_check_path must begin with /."
  }
}

variable "health_check_healthy_threshold" {
  description = "Number of consecutive successful health checks required before a target is declared healthy."
  type        = number
  default     = 2

  validation {
    condition     = var.health_check_healthy_threshold >= 2 && var.health_check_healthy_threshold <= 10
    error_message = "health_check_healthy_threshold must be between 2 and 10."
  }
}

variable "health_check_unhealthy_threshold" {
  description = "Number of consecutive failed health checks required before a target is declared unhealthy."
  type        = number
  default     = 3

  validation {
    condition     = var.health_check_unhealthy_threshold >= 2 && var.health_check_unhealthy_threshold <= 10
    error_message = "health_check_unhealthy_threshold must be between 2 and 10."
  }
}

variable "health_check_interval" {
  description = "Interval in seconds between ALB health checks."
  type        = number
  default     = 30

  validation {
    condition     = var.health_check_interval >= 5 && var.health_check_interval <= 300
    error_message = "health_check_interval must be between 5 and 300 seconds."
  }
}

variable "health_check_timeout" {
  description = "Timeout in seconds for a single ALB health check request. Must be less than health_check_interval."
  type        = number
  default     = 5

  validation {
    condition     = var.health_check_timeout >= 2 && var.health_check_timeout <= 120
    error_message = "health_check_timeout must be between 2 and 120 seconds."
  }
}

variable "health_check_matcher" {
  description = "HTTP response code(s) that constitute a healthy response. Accepts ranges (200-299) and comma-separated values (200,204)."
  type        = string
  default     = "200"
}

variable "deregistration_delay" {
  description = "Seconds the ALB waits before deregistering a draining target. Tune to match your application's in-flight request lifetime."
  type        = number
  default     = 30

  validation {
    condition     = var.deregistration_delay >= 0 && var.deregistration_delay <= 3600
    error_message = "deregistration_delay must be between 0 and 3600 seconds."
  }
}

# ------------------------------------------------------------------------------
# HTTPS / TLS
# ------------------------------------------------------------------------------

variable "enable_https" {
  description = "Attach an HTTPS listener (port 443) to the ALB and redirect HTTP to HTTPS. Requires certificate_arn."
  type        = bool
  default     = false
}

variable "certificate_arn" {
  description = "ARN of an ACM certificate to attach to the ALB HTTPS listener. Required when enable_https = true."
  type        = string
  default     = ""

  validation {
    condition     = var.certificate_arn == "" || can(regex("^arn:aws:acm:", var.certificate_arn))
    error_message = "certificate_arn must be empty or a valid ACM certificate ARN (arn:aws:acm:...)."
  }
}

variable "ssl_policy" {
  description = "SSL/TLS policy for the HTTPS listener. ELBSecurityPolicy-TLS13-1-2-2021-06 is the recommended modern policy."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

# ------------------------------------------------------------------------------
# Autoscaling
# ------------------------------------------------------------------------------

variable "enable_autoscaling" {
  description = "Enable Application Auto Scaling for the ECS service with target tracking policies."
  type        = bool
  default     = false
}

variable "min_count" {
  description = "Minimum number of tasks maintained by autoscaling. Ignored when enable_autoscaling = false."
  type        = number
  default     = 2

  validation {
    condition     = var.min_count >= 1
    error_message = "min_count must be >= 1."
  }
}

variable "max_count" {
  description = "Maximum number of tasks the autoscaler may scale out to. Ignored when enable_autoscaling = false."
  type        = number
  default     = 10

  validation {
    condition     = var.max_count >= 1
    error_message = "max_count must be >= 1."
  }
}

variable "autoscaling_cpu_target" {
  description = "Target CPU utilization percentage (0-100) for the autoscaling target tracking policy. Set to null to disable CPU-based scaling."
  type        = number
  default     = 70

  validation {
    condition     = var.autoscaling_cpu_target == null || (var.autoscaling_cpu_target > 0 && var.autoscaling_cpu_target <= 100)
    error_message = "autoscaling_cpu_target must be null or a value between 1 and 100."
  }
}

variable "autoscaling_memory_target" {
  description = "Target memory utilization percentage (0-100) for the autoscaling target tracking policy. Set to null to disable memory-based scaling."
  type        = number
  default     = null

  validation {
    condition     = var.autoscaling_memory_target == null || (var.autoscaling_memory_target > 0 && var.autoscaling_memory_target <= 100)
    error_message = "autoscaling_memory_target must be null or a value between 1 and 100."
  }
}

variable "scale_in_cooldown" {
  description = "Cooldown period in seconds after a scale-in activity completes before another scale-in can start."
  type        = number
  default     = 300
}

variable "scale_out_cooldown" {
  description = "Cooldown period in seconds after a scale-out activity completes before another scale-out can start."
  type        = number
  default     = 60
}

# ------------------------------------------------------------------------------
# Service Discovery (Cloud Map)
# ------------------------------------------------------------------------------

variable "enable_service_discovery" {
  description = "Register the ECS service in AWS Cloud Map for DNS-based service-to-service discovery within the VPC."
  type        = bool
  default     = false
}

variable "service_discovery_namespace_id" {
  description = "ID of an existing Cloud Map private DNS namespace. Required when enable_service_discovery = true."
  type        = string
  default     = ""
}

variable "service_discovery_dns_ttl" {
  description = "TTL in seconds for Cloud Map DNS records."
  type        = number
  default     = 10
}

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------

variable "log_retention_days" {
  description = "Number of days to retain container logs in CloudWatch Logs."
  type        = number
  default     = 30

  validation {
    condition = contains(
      [0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.log_retention_days
    )
    error_message = "log_retention_days must be a value accepted by CloudWatch Logs (0, 1, 3, 5, 7, 14, 30, 60, 90, ...)."
  }
}

# ------------------------------------------------------------------------------
# Tags
# ------------------------------------------------------------------------------

variable "tags" {
  description = "Map of additional tags merged onto all resources. Module-managed tags (ManagedBy, Module) are always applied."
  type        = map(string)
  default     = {}
}
