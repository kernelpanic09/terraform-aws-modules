output "saml_provider_arn" {
  description = "ARN of the IAM SAML Identity Provider created in AWS for Okta."
  value       = aws_iam_saml_provider.okta.arn
}

output "okta_app_id" {
  description = "ID of the Okta SAML application integration."
  value       = okta_app_saml.aws.id
}

output "okta_app_metadata_url" {
  description = "URL of the Okta SAML metadata document for this application."
  value       = okta_app_saml.aws.metadata_url
}

output "role_arns" {
  description = "Map of role name to IAM role ARN for all federated roles created by this module."
  value       = { for name, role in aws_iam_role.federated : name => role.arn }
}

output "role_names" {
  description = "Map of role name to IAM role name for all federated roles created by this module."
  value       = { for name, role in aws_iam_role.federated : name => role.name }
}

output "okta_group_ids" {
  description = "Map of role name to Okta group ID for all groups created by this module."
  value       = { for name, group in okta_group.role_groups : name => group.id }
}

output "okta_group_names" {
  description = "Map of role name to Okta group name for all groups created by this module."
  value       = { for name, group in okta_group.role_groups : name => group.name }
}

output "saml_login_url" {
  description = "Okta sign-in URL for the AWS SAML application. Users navigate here to initiate federated sign-in."
  value       = okta_app_saml.aws.sign_on_url
}
