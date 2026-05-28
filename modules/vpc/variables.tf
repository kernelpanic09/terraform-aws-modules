variable "name" {
  description = "Name prefix for all VPC resources"
  type        = string

  validation {
    condition     = length(var.name) > 0 && length(var.name) <= 32
    error_message = "Name must be between 1 and 32 characters."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "Must be a valid CIDR block."
  }
}

variable "az_count" {
  description = "Number of availability zones to use. Must not exceed the number of AZs available in the target region."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 1 && var.az_count <= 6
    error_message = "AZ count must be between 1 and 6."
  }
}

variable "subnet_newbits" {
  description = "Number of additional bits to extend the VPC CIDR prefix when calculating subnet CIDRs via cidrsubnet(). For a /16 VPC, newbits = 8 yields /24 subnets."
  type        = number
  default     = 8
}

variable "single_nat_gateway" {
  description = "Use a single NAT Gateway instead of one per AZ. Reduces cost for non-production environments at the expense of AZ-level fault isolation."
  type        = bool
  default     = false
}

variable "enable_flow_logs" {
  description = "Enable VPC Flow Logs to CloudWatch Logs. Creates a dedicated log group, IAM role, and role policy."
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "Retention period in days for the VPC Flow Logs CloudWatch log group."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Map of additional tags to apply to all resources. Merged with module-managed tags (ManagedBy, Module)."
  type        = map(string)
  default     = {}
}
