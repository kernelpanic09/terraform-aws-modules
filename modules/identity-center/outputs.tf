output "instance_arn" {
  description = "ARN of the Identity Center instance (singleton per organization)"
  value       = local.instance_arn
}

output "identity_store_id" {
  description = "ID of the Identity Store associated with the Identity Center instance"
  value       = local.identity_store_id
}

output "permission_set_arns" {
  description = "Map of permission set name to ARN"
  value       = { for name, ps in aws_ssoadmin_permission_set.this : name => ps.arn }
}

output "group_ids" {
  description = "Map of group display name to Identity Store group ID"
  value       = { for name, g in aws_identitystore_group.this : name => g.group_id }
}

output "assignment_keys" {
  description = "List of account assignment keys in the form group-permissionset-accountid"
  value       = [for a in aws_ssoadmin_account_assignment.this : a.id]
}
