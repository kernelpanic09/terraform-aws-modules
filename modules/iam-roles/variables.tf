###############################################################################
# General
###############################################################################

variable "name_prefix" {
  description = "Prefix applied to every IAM role and policy name created by this module."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,30}$", var.name_prefix))
    error_message = "name_prefix must be 1-31 characters, start with alphanumeric, and contain only letters, numbers, hyphens, or underscores."
  }
}

variable "tags" {
  description = "Map of tags applied to all resources created by this module."
  type        = map(string)
  default     = {}
}

###############################################################################
# Permissions boundary
###############################################################################

variable "permissions_boundary_arn" {
  description = "ARN of an IAM managed policy to use as the permissions boundary on the read-only, developer, and CI/CD roles. Leave empty to skip attaching a boundary."
  type        = string
  default     = ""

  validation {
    condition     = var.permissions_boundary_arn == "" || can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:policy/.+$", var.permissions_boundary_arn))
    error_message = "permissions_boundary_arn must be empty or a valid IAM policy ARN."
  }
}

###############################################################################
# Admin role
###############################################################################

variable "create_admin_role" {
  description = "Whether to create the admin role."
  type        = bool
  default     = true
}

variable "admin_role_name" {
  description = "Override the admin role name. Defaults to {name_prefix}-admin."
  type        = string
  default     = ""
}

variable "admin_session_duration" {
  description = "Maximum CLI/console session duration in seconds for the admin role (900-43200)."
  type        = number
  default     = 3600

  validation {
    condition     = var.admin_session_duration >= 900 && var.admin_session_duration <= 43200
    error_message = "admin_session_duration must be between 900 and 43200 seconds."
  }
}

variable "admin_require_mfa" {
  description = "When true, the admin role trust policy requires the caller to have authenticated with MFA."
  type        = bool
  default     = true
}

variable "admin_trusted_account_ids" {
  description = "List of AWS account IDs permitted to assume the admin role. At least one of admin_trusted_account_ids, admin_trusted_saml_provider_arns, or admin_trusted_identity_center must be configured when create_admin_role is true."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.admin_trusted_account_ids : can(regex("^[0-9]{12}$", id))])
    error_message = "Each entry in admin_trusted_account_ids must be a 12-digit AWS account ID."
  }
}

variable "admin_trusted_saml_provider_arns" {
  description = "List of SAML provider ARNs permitted to federate to the admin role."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for arn in var.admin_trusted_saml_provider_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:saml-provider/.+$", arn))])
    error_message = "Each entry must be a valid SAML provider ARN."
  }
}

variable "admin_trusted_identity_center" {
  description = "When true, trusts AWS Identity Center (SSO) service principal in the trust policy."
  type        = bool
  default     = false
}

###############################################################################
# Read-only role
###############################################################################

variable "create_readonly_role" {
  description = "Whether to create the read-only role."
  type        = bool
  default     = true
}

variable "readonly_role_name" {
  description = "Override the read-only role name. Defaults to {name_prefix}-readonly."
  type        = string
  default     = ""
}

variable "readonly_session_duration" {
  description = "Maximum CLI/console session duration in seconds for the read-only role (900-43200)."
  type        = number
  default     = 3600

  validation {
    condition     = var.readonly_session_duration >= 900 && var.readonly_session_duration <= 43200
    error_message = "readonly_session_duration must be between 900 and 43200 seconds."
  }
}

variable "readonly_trusted_account_ids" {
  description = "List of AWS account IDs permitted to assume the read-only role."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.readonly_trusted_account_ids : can(regex("^[0-9]{12}$", id))])
    error_message = "Each entry in readonly_trusted_account_ids must be a 12-digit AWS account ID."
  }
}

variable "readonly_trusted_identity_center" {
  description = "When true, trusts AWS Identity Center (SSO) service principal in the trust policy."
  type        = bool
  default     = false
}

###############################################################################
# Developer role
###############################################################################

variable "create_developer_role" {
  description = "Whether to create the developer role."
  type        = bool
  default     = true
}

variable "developer_role_name" {
  description = "Override the developer role name. Defaults to {name_prefix}-developer."
  type        = string
  default     = ""
}

variable "developer_session_duration" {
  description = "Maximum CLI/console session duration in seconds for the developer role (900-43200)."
  type        = number
  default     = 7200

  validation {
    condition     = var.developer_session_duration >= 900 && var.developer_session_duration <= 43200
    error_message = "developer_session_duration must be between 900 and 43200 seconds."
  }
}

variable "developer_trusted_account_ids" {
  description = "List of AWS account IDs permitted to assume the developer role."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.developer_trusted_account_ids : can(regex("^[0-9]{12}$", id))])
    error_message = "Each entry in developer_trusted_account_ids must be a 12-digit AWS account ID."
  }
}

variable "developer_trusted_identity_center" {
  description = "When true, trusts AWS Identity Center (SSO) service principal in the trust policy."
  type        = bool
  default     = false
}

variable "developer_extra_policy_arns" {
  description = "Additional managed policy ARNs to attach to the developer role (e.g., service-specific policies)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for arn in var.developer_extra_policy_arns : can(regex("^arn:aws[a-z-]*:iam::", arn))])
    error_message = "Each entry must be a valid IAM policy ARN."
  }
}

variable "developer_allowed_s3_bucket_arns" {
  description = "List of S3 bucket ARNs (and their /* path) that the developer role can read and write. Defaults to all buckets when empty."
  type        = list(string)
  default     = ["arn:aws:s3:::*", "arn:aws:s3:::*/*"]
}

###############################################################################
# CI/CD role (GitHub Actions OIDC)
###############################################################################

variable "create_cicd_role" {
  description = "Whether to create the CI/CD role for GitHub Actions OIDC."
  type        = bool
  default     = true
}

variable "cicd_role_name" {
  description = "Override the CI/CD role name. Defaults to {name_prefix}-cicd."
  type        = string
  default     = ""
}

variable "cicd_session_duration" {
  description = "Maximum session duration in seconds for the CI/CD role (900-3600 recommended for OIDC)."
  type        = number
  default     = 3600

  validation {
    condition     = var.cicd_session_duration >= 900 && var.cicd_session_duration <= 43200
    error_message = "cicd_session_duration must be between 900 and 43200 seconds."
  }
}

variable "github_org" {
  description = "GitHub organization or username that owns the repositories permitted to assume the CI/CD role."
  type        = string
  default     = ""
}

variable "github_repositories" {
  description = "List of GitHub repository names (without the org prefix) allowed to assume the CI/CD role. Use '*' to allow all repos in the org. Requires github_org to be set."
  type        = list(string)
  default     = ["*"]
}

variable "github_branches" {
  description = "List of branch/tag/environment patterns permitted in the OIDC subject claim. Defaults to any ref ('*'). Example: ['ref:refs/heads/main', 'environment:production']."
  type        = list(string)
  default     = ["*"]
}

variable "create_github_oidc_provider" {
  description = "Whether to create the GitHub Actions OIDC identity provider in this account. Set to false if the provider already exists."
  type        = bool
  default     = true
}

variable "cicd_extra_policy_arns" {
  description = "Additional managed policy ARNs to attach to the CI/CD role."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for arn in var.cicd_extra_policy_arns : can(regex("^arn:aws[a-z-]*:iam::", arn))])
    error_message = "Each entry must be a valid IAM policy ARN."
  }
}

variable "cicd_permissions_boundary_arn" {
  description = "ARN of an IAM managed policy to use as the permissions boundary specifically on the CI/CD role. Overrides permissions_boundary_arn when set."
  type        = string
  default     = ""

  validation {
    condition     = var.cicd_permissions_boundary_arn == "" || can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:policy/.+$", var.cicd_permissions_boundary_arn))
    error_message = "cicd_permissions_boundary_arn must be empty or a valid IAM policy ARN."
  }
}
