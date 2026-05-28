# ------------------------------------------------------------------------------
# Core cluster configuration
# ------------------------------------------------------------------------------

variable "cluster_name" {
  description = "Name of the EKS cluster. Used as a prefix for all associated resources."
  type        = string

  validation {
    condition     = length(var.cluster_name) >= 1 && length(var.cluster_name) <= 100 && can(regex("^[a-zA-Z][a-zA-Z0-9-]*$", var.cluster_name))
    error_message = "cluster_name must be 1-100 characters, start with a letter, and contain only alphanumeric characters and hyphens."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster control plane. Must be a version supported by EKS (e.g. '1.30')."
  type        = string
  default     = "1.30"

  validation {
    condition     = can(regex("^1\\.(2[5-9]|[3-9][0-9])$", var.kubernetes_version))
    error_message = "kubernetes_version must be a supported EKS version in the format '1.X' (e.g. '1.30'). Minimum supported version is 1.25."
  }
}

# ------------------------------------------------------------------------------
# Networking
# ------------------------------------------------------------------------------

variable "vpc_id" {
  description = "ID of the VPC in which to create the EKS cluster and node groups."
  type        = string

  validation {
    condition     = can(regex("^vpc-[a-f0-9]+$", var.vpc_id))
    error_message = "vpc_id must be a valid VPC ID starting with 'vpc-'."
  }
}

variable "subnet_ids" {
  description = "List of private subnet IDs for the EKS cluster and managed node groups. Must span at least two availability zones for HA."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "At least two subnet IDs are required for high availability."
  }

  validation {
    condition     = alltrue([for s in var.subnet_ids : can(regex("^subnet-[a-f0-9]+$", s))])
    error_message = "All subnet_ids must be valid subnet IDs starting with 'subnet-'."
  }
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs. Required when endpoint_public_access is true and you want the public endpoint to be reachable only from specific CIDRs. Not used by node groups."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for s in var.public_subnet_ids : can(regex("^subnet-[a-f0-9]+$", s))])
    error_message = "All public_subnet_ids must be valid subnet IDs starting with 'subnet-'."
  }
}

# ------------------------------------------------------------------------------
# API server endpoint access
# ------------------------------------------------------------------------------

variable "endpoint_public_access" {
  description = "Whether to enable the public API server endpoint. Set to false for private clusters (requires VPN or Direct Connect to reach the cluster)."
  type        = bool
  default     = true
}

variable "endpoint_private_access" {
  description = "Whether to enable the private API server endpoint. Nodes always communicate via the private endpoint regardless of this setting."
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "List of CIDR blocks allowed to reach the public API server endpoint. Ignored when endpoint_public_access is false. Defaults to 0.0.0.0/0 (fully public)."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = alltrue([for c in var.public_access_cidrs : can(cidrhost(c, 0))])
    error_message = "All public_access_cidrs must be valid CIDR blocks."
  }
}

# ------------------------------------------------------------------------------
# Control plane logging
# ------------------------------------------------------------------------------

variable "enabled_cluster_log_types" {
  description = "List of EKS control plane log types to send to CloudWatch. Valid values: api, audit, authenticator, controllerManager, scheduler."
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  validation {
    condition = alltrue([
      for t in var.enabled_cluster_log_types :
      contains(["api", "audit", "authenticator", "controllerManager", "scheduler"], t)
    ])
    error_message = "enabled_cluster_log_types must only contain: api, audit, authenticator, controllerManager, scheduler."
  }
}

variable "log_retention_days" {
  description = "Number of days to retain EKS control plane logs in CloudWatch. Valid values: 0 (never expire), 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653."
  type        = number
  default     = 90

  validation {
    condition     = contains([0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a valid CloudWatch Logs retention period."
  }
}

# ------------------------------------------------------------------------------
# Managed node groups
# ------------------------------------------------------------------------------

variable "node_groups" {
  description = <<-EOT
    Map of managed node group configurations. Each key becomes the node group name suffix.
    Fields:
      name              - Display name for the node group (used in tags).
      instance_types    - List of EC2 instance types. Multiple types enable instance flexibility for Spot.
      capacity_type     - "ON_DEMAND" or "SPOT".
      ami_type          - AMI type for nodes. Defaults to "AL2_x86_64". Use "AL2_ARM_64" for Graviton.
      disk_size         - EBS root volume size in GiB.
      min_size          - Minimum number of nodes.
      max_size          - Maximum number of nodes.
      desired_size      - Initial desired number of nodes.
      labels            - Kubernetes labels to apply to all nodes in the group.
      taints            - List of Kubernetes taints. Each taint is an object with key, value, effect.
      subnet_ids        - Override subnet IDs for this node group. Defaults to var.subnet_ids.
  EOT
  type = map(object({
    name           = string
    instance_types = list(string)
    capacity_type  = optional(string, "ON_DEMAND")
    ami_type       = optional(string, "AL2_x86_64")
    disk_size      = optional(number, 50)
    min_size       = number
    max_size       = number
    desired_size   = number
    labels         = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = optional(string, "")
      effect = string
    })), [])
    subnet_ids = optional(list(string), [])
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, ng in var.node_groups : contains(["ON_DEMAND", "SPOT"], ng.capacity_type)
    ])
    error_message = "All node_groups[*].capacity_type must be 'ON_DEMAND' or 'SPOT'."
  }

  validation {
    condition = alltrue([
      for k, ng in var.node_groups : ng.min_size >= 0 && ng.max_size >= ng.min_size && ng.desired_size >= ng.min_size && ng.desired_size <= ng.max_size
    ])
    error_message = "Node group scaling config must satisfy: min_size <= desired_size <= max_size, and min_size >= 0."
  }

  validation {
    condition = alltrue([
      for k, ng in var.node_groups : length(ng.instance_types) >= 1
    ])
    error_message = "Each node group must specify at least one instance type."
  }

  validation {
    condition = alltrue(flatten([
      for k, ng in var.node_groups : [
        for t in ng.taints : contains(["NO_SCHEDULE", "NO_EXECUTE", "PREFER_NO_SCHEDULE"], t.effect)
      ]
    ]))
    error_message = "Taint effect must be 'NO_SCHEDULE', 'NO_EXECUTE', or 'PREFER_NO_SCHEDULE'."
  }

  validation {
    condition = alltrue([
      for k, ng in var.node_groups : contains(["AL2_x86_64", "AL2_x86_64_GPU", "AL2_ARM_64", "BOTTLEROCKET_x86_64", "BOTTLEROCKET_ARM_64", "WINDOWS_CORE_2019_x86_64", "WINDOWS_FULL_2019_x86_64", "WINDOWS_CORE_2022_x86_64", "WINDOWS_FULL_2022_x86_64", "AL2023_x86_64_STANDARD", "AL2023_ARM_64_STANDARD"], ng.ami_type)
    ])
    error_message = "ami_type must be a valid EKS managed node group AMI type."
  }
}

# ------------------------------------------------------------------------------
# EKS add-ons
# ------------------------------------------------------------------------------

variable "addons" {
  description = <<-EOT
    Map of EKS add-ons to install. Key is the add-on name (e.g. "vpc-cni").
    Fields:
      version                     - Add-on version string (e.g. "v1.18.1-eksbuild.1"). Set to null to use the default for the cluster version.
      resolve_conflicts_on_create - How to handle config conflicts on initial install. "OVERWRITE" or "NONE".
      resolve_conflicts_on_update - How to handle config conflicts on update. "OVERWRITE" or "NONE" or "PRESERVE".
      configuration_values        - JSON string of add-on configuration values. Set to null for defaults.
      preserve_on_delete          - Whether to preserve add-on resources when the add-on is deleted.
  EOT
  type = map(object({
    version                     = optional(string, null)
    resolve_conflicts_on_create = optional(string, "OVERWRITE")
    resolve_conflicts_on_update = optional(string, "OVERWRITE")
    configuration_values        = optional(string, null)
    preserve_on_delete          = optional(bool, false)
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, a in var.addons : contains(["OVERWRITE", "NONE"], a.resolve_conflicts_on_create)
    ])
    error_message = "addons[*].resolve_conflicts_on_create must be 'OVERWRITE' or 'NONE'."
  }

  validation {
    condition = alltrue([
      for k, a in var.addons : contains(["OVERWRITE", "NONE", "PRESERVE"], a.resolve_conflicts_on_update)
    ])
    error_message = "addons[*].resolve_conflicts_on_update must be 'OVERWRITE', 'NONE', or 'PRESERVE'."
  }
}

# ------------------------------------------------------------------------------
# Cluster access entries (replaces aws-auth ConfigMap)
# ------------------------------------------------------------------------------

variable "cluster_admin_principals" {
  description = <<-EOT
    List of IAM principal ARNs to grant AmazonEKSClusterAdminPolicy access via EKS access entries.
    This replaces the legacy aws-auth ConfigMap approach. Each principal (IAM role or user ARN) will
    be added as an access entry and associated with the built-in AmazonEKSClusterAdminPolicy.
    Example: ["arn:aws:iam::123456789012:role/MyAdminRole", "arn:aws:iam::123456789012:user/alice"]
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for arn in var.cluster_admin_principals : can(regex("^arn:aws:iam::[0-9]{12}:(role|user)/", arn))])
    error_message = "All cluster_admin_principals must be valid IAM role or user ARNs (arn:aws:iam::ACCOUNT_ID:role/NAME or arn:aws:iam::ACCOUNT_ID:user/NAME)."
  }
}

# ------------------------------------------------------------------------------
# IRSA - AWS Load Balancer Controller
# ------------------------------------------------------------------------------

variable "enable_lb_controller_irsa" {
  description = "Whether to create an IRSA (IAM Roles for Service Accounts) role for the AWS Load Balancer Controller. The role ARN is available as the lb_controller_role_arn output."
  type        = bool
  default     = false
}

variable "lb_controller_namespace" {
  description = "Kubernetes namespace where the AWS Load Balancer Controller service account will live. Used in the IRSA trust policy condition."
  type        = string
  default     = "kube-system"

  validation {
    condition     = length(var.lb_controller_namespace) > 0
    error_message = "lb_controller_namespace must not be empty."
  }
}

variable "lb_controller_service_account" {
  description = "Kubernetes service account name for the AWS Load Balancer Controller. Used in the IRSA trust policy condition."
  type        = string
  default     = "aws-load-balancer-controller"

  validation {
    condition     = length(var.lb_controller_service_account) > 0
    error_message = "lb_controller_service_account must not be empty."
  }
}

# ------------------------------------------------------------------------------
# IRSA - Cluster Autoscaler
# ------------------------------------------------------------------------------

variable "enable_cluster_autoscaler_irsa" {
  description = "Whether to create an IRSA role for the Cluster Autoscaler. The role ARN is available as the cluster_autoscaler_role_arn output."
  type        = bool
  default     = false
}

variable "cluster_autoscaler_namespace" {
  description = "Kubernetes namespace where the Cluster Autoscaler service account will live. Used in the IRSA trust policy condition."
  type        = string
  default     = "kube-system"

  validation {
    condition     = length(var.cluster_autoscaler_namespace) > 0
    error_message = "cluster_autoscaler_namespace must not be empty."
  }
}

variable "cluster_autoscaler_service_account" {
  description = "Kubernetes service account name for the Cluster Autoscaler. Used in the IRSA trust policy condition."
  type        = string
  default     = "cluster-autoscaler"

  validation {
    condition     = length(var.cluster_autoscaler_service_account) > 0
    error_message = "cluster_autoscaler_service_account must not be empty."
  }
}

# ------------------------------------------------------------------------------
# Tags
# ------------------------------------------------------------------------------

variable "tags" {
  description = "Map of additional tags to apply to all resources. Merged with module-managed tags (ManagedBy, Module)."
  type        = map(string)
  default     = {}
}
