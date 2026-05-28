###############################################################################
# Admin role
###############################################################################

output "admin_role_arn" {
  description = "ARN of the admin IAM role. Empty string when create_admin_role is false."
  value       = var.create_admin_role ? aws_iam_role.admin[0].arn : ""
}

output "admin_role_name" {
  description = "Name of the admin IAM role."
  value       = var.create_admin_role ? aws_iam_role.admin[0].name : ""
}

output "admin_role_unique_id" {
  description = "Stable unique identifier for the admin role."
  value       = var.create_admin_role ? aws_iam_role.admin[0].unique_id : ""
}

###############################################################################
# Read-only role
###############################################################################

output "readonly_role_arn" {
  description = "ARN of the read-only IAM role. Empty string when create_readonly_role is false."
  value       = var.create_readonly_role ? aws_iam_role.readonly[0].arn : ""
}

output "readonly_role_name" {
  description = "Name of the read-only IAM role."
  value       = var.create_readonly_role ? aws_iam_role.readonly[0].name : ""
}

output "readonly_role_unique_id" {
  description = "Stable unique identifier for the read-only role."
  value       = var.create_readonly_role ? aws_iam_role.readonly[0].unique_id : ""
}

###############################################################################
# Developer role
###############################################################################

output "developer_role_arn" {
  description = "ARN of the developer IAM role. Empty string when create_developer_role is false."
  value       = var.create_developer_role ? aws_iam_role.developer[0].arn : ""
}

output "developer_role_name" {
  description = "Name of the developer IAM role."
  value       = var.create_developer_role ? aws_iam_role.developer[0].name : ""
}

output "developer_role_unique_id" {
  description = "Stable unique identifier for the developer role."
  value       = var.create_developer_role ? aws_iam_role.developer[0].unique_id : ""
}

output "developer_policy_arn" {
  description = "ARN of the custom IAM policy attached to the developer role."
  value       = var.create_developer_role ? aws_iam_policy.developer[0].arn : ""
}

###############################################################################
# CI/CD role
###############################################################################

output "cicd_role_arn" {
  description = "ARN of the CI/CD IAM role for GitHub Actions OIDC. Empty string when create_cicd_role is false."
  value       = var.create_cicd_role ? aws_iam_role.cicd[0].arn : ""
}

output "cicd_role_name" {
  description = "Name of the CI/CD IAM role."
  value       = var.create_cicd_role ? aws_iam_role.cicd[0].name : ""
}

output "cicd_role_unique_id" {
  description = "Stable unique identifier for the CI/CD role."
  value       = var.create_cicd_role ? aws_iam_role.cicd[0].unique_id : ""
}

###############################################################################
# GitHub OIDC provider
###############################################################################

output "github_oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC identity provider. Empty string when create_cicd_role is false."
  value       = local.github_oidc_provider_arn
}

###############################################################################
# All role ARNs map (useful for consuming modules)
###############################################################################

output "role_arns" {
  description = "Map of role key to ARN for all roles created by this module."
  value = {
    admin     = var.create_admin_role ? aws_iam_role.admin[0].arn : ""
    readonly  = var.create_readonly_role ? aws_iam_role.readonly[0].arn : ""
    developer = var.create_developer_role ? aws_iam_role.developer[0].arn : ""
    cicd      = var.create_cicd_role ? aws_iam_role.cicd[0].arn : ""
  }
}
