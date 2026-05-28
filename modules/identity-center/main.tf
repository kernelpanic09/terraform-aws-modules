##############################################################################
# AWS IAM Identity Center (SSO) Module
#
# References the singleton Identity Center instance (one per org, cannot be
# created via Terraform), then manages permission sets, directory groups, and
# account assignments as code.
##############################################################################

data "aws_ssoadmin_instances" "this" {}

locals {
  instance_arn      = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]

  common_tags = merge(var.tags, {
    ManagedBy = "terraform"
    Module    = "identity-center"
  })

  # Keyed map for permission sets to enable for_each
  permission_set_map = { for ps in var.permission_sets : ps.name => ps }

  # Keyed map for groups to enable for_each
  group_map = { for g in var.groups : g.name => g }

  # Flatten account assignments into individual (group, permission set, account) triples
  account_assignments = flatten([
    for assignment in var.account_assignments : [
      for account_id in assignment.account_ids : {
        key             = "${assignment.group_name}-${assignment.permission_set_name}-${account_id}"
        group_name      = assignment.group_name
        permission_set  = assignment.permission_set_name
        account_id      = account_id
      }
    ]
  ])

  # Flatten managed policy attachments across all permission sets
  managed_policy_attachments = flatten([
    for ps_name, ps in local.permission_set_map : [
      for policy_arn in ps.managed_policy_arns : {
        key        = "${ps_name}-${replace(policy_arn, "/[^a-zA-Z0-9]/", "-")}"
        ps_name    = ps_name
        policy_arn = policy_arn
      }
    ]
  ])
}

##############################################################################
# Permission Sets
##############################################################################

resource "aws_ssoadmin_permission_set" "this" {
  for_each = local.permission_set_map

  name             = each.value.name
  description      = each.value.description
  instance_arn     = local.instance_arn
  session_duration = each.value.session_duration
  relay_state      = each.value.relay_state

  tags = merge(local.common_tags, { Name = each.value.name })
}

resource "aws_ssoadmin_managed_policy_attachment" "this" {
  for_each = {
    for pair in local.managed_policy_attachments : pair.key => pair
  }

  instance_arn       = local.instance_arn
  managed_policy_arn = each.value.policy_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.value.ps_name].arn

  depends_on = [aws_ssoadmin_permission_set.this]
}

resource "aws_ssoadmin_permission_set_inline_policy" "this" {
  for_each = {
    for name, ps in local.permission_set_map : name => ps
    if ps.inline_policy != null
  }

  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.key].arn
  inline_policy      = each.value.inline_policy

  depends_on = [aws_ssoadmin_permission_set.this]
}

##############################################################################
# Identity Store Groups
##############################################################################

resource "aws_identitystore_group" "this" {
  for_each = local.group_map

  identity_store_id = local.identity_store_id
  display_name      = each.value.name
  description       = each.value.description
}

##############################################################################
# Account Assignments
# Each assignment is the triple: group x permission set x AWS account
##############################################################################

resource "aws_ssoadmin_account_assignment" "this" {
  for_each = { for a in local.account_assignments : a.key => a }

  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.value.permission_set].arn

  principal_id   = aws_identitystore_group.this[each.value.group_name].group_id
  principal_type = "GROUP"

  target_id   = each.value.account_id
  target_type = "AWS_ACCOUNT"

  depends_on = [
    aws_identitystore_group.this,
    aws_ssoadmin_permission_set.this,
  ]
}
