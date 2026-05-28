variable "permission_sets" {
  description = "List of permission sets to create in Identity Center"
  type = list(object({
    name                = string
    description         = string
    session_duration    = optional(string, "PT4H")
    relay_state         = optional(string, null)
    managed_policy_arns = optional(list(string), [])
    inline_policy       = optional(string, null)
  }))
  default = []

  validation {
    condition = alltrue([
      for ps in var.permission_sets : can(regex("^[a-zA-Z0-9_-]+$", ps.name))
    ])
    error_message = "Permission set names must be alphanumeric with hyphens and underscores only."
  }
}

variable "groups" {
  description = "List of groups to create in the Identity Center directory"
  type = list(object({
    name        = string
    description = optional(string, "")
  }))
  default = []
}

variable "account_assignments" {
  description = "Maps groups to permission sets in specific AWS accounts. Each entry specifies a group, a permission set, and one or more account IDs to assign them to."
  type = list(object({
    group_name          = string
    permission_set_name = string
    account_ids         = list(string)
  }))
  default = []

  validation {
    condition = alltrue(flatten([
      for a in var.account_assignments : [
        for id in a.account_ids : can(regex("^[0-9]{12}$", id))
      ]
    ]))
    error_message = "Account IDs must be 12-digit numbers."
  }
}

variable "tags" {
  description = "Tags to apply to all taggable resources"
  type        = map(string)
  default     = {}
}
