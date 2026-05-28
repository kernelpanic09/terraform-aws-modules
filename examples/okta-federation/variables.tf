variable "okta_org_name" {
  description = "Okta organization subdomain (the part before .okta.com)."
  type        = string
}

variable "okta_api_token" {
  description = "Okta API token with permissions to manage applications and groups. Set via TF_VAR_okta_api_token or the OKTA_API_TOKEN environment variable."
  type        = string
  sensitive   = true
}

variable "aws_region" {
  description = "AWS region in which to create IAM resources."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name appended to resource names to support multi-environment setups (e.g. production, staging)."
  type        = string
  default     = "production"

  validation {
    condition     = contains(["production", "staging", "development"], var.environment)
    error_message = "environment must be one of: production, staging, development."
  }
}
