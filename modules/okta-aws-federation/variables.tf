variable "okta_app_label" {
  description = "Display label for the Okta SAML application that appears in the Okta dashboard."
  type        = string
  default     = "Amazon Web Services"
}

variable "saml_provider_name" {
  description = "Name for the IAM SAML Identity Provider created in AWS. Must contain only alphanumeric characters and hyphens."
  type        = string
  default     = "Okta"

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]+$", var.saml_provider_name))
    error_message = "saml_provider_name must contain only alphanumeric characters and hyphens."
  }
}

variable "okta_group_prefix" {
  description = "Prefix applied to Okta group names to namespace them for AWS federation. Groups will be named <prefix><role_name>, e.g. 'aws-admin'."
  type        = string
  default     = "aws-"
}

variable "session_duration" {
  description = "Maximum session duration in seconds for federated IAM role sessions. Must be between 900 (15 minutes) and 43200 (12 hours)."
  type        = number
  default     = 3600

  validation {
    condition     = var.session_duration >= 900 && var.session_duration <= 43200
    error_message = "session_duration must be between 900 and 43200 seconds."
  }
}

variable "roles" {
  description = "List of AWS IAM roles to create with corresponding Okta group mapping. Each role gets its own Okta group named <okta_group_prefix><name> and a trust policy allowing SAML federation from Okta."
  type = list(object({
    name                     = string
    description              = string
    policy_arns              = list(string)
    permissions_boundary_arn = optional(string, null)
    inline_policy            = optional(string, null)
  }))

  validation {
    condition     = length(var.roles) > 0
    error_message = "At least one role must be defined."
  }

  validation {
    condition = alltrue([
      for r in var.roles : can(regex("^[a-zA-Z0-9+=,.@_/-]+$", r.name))
    ])
    error_message = "Role names must contain only alphanumeric characters and the following special characters: +=,.@_/-"
  }
}

variable "tags" {
  description = "Map of tags to apply to all taggable AWS resources created by this module."
  type        = map(string)
  default     = {}
}
