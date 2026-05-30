locals {
  common_tags = merge(var.tags, { ManagedBy = "terraform", Module = "okta-aws-federation" })

  role_definitions = { for r in var.roles : r.name => r }
}

# --- Okta SAML Application for AWS ---

resource "okta_app_saml" "aws" {
  label             = var.okta_app_label
  preconfigured_app = "amazon_aws"
  status            = "ACTIVE"

  user_name_template      = "$${source.login}"
  user_name_template_type = "BUILT_IN"

  attribute_statements {
    name      = "https://aws.amazon.com/SAML/Attributes/RoleSessionName"
    namespace = "urn:oasis:names:tc:SAML:2.0:attrname-format:uri"
    type      = "EXPRESSION"
    values    = ["user.email"]
  }

  attribute_statements {
    name      = "https://aws.amazon.com/SAML/Attributes/SessionDuration"
    namespace = "urn:oasis:names:tc:SAML:2.0:attrname-format:uri"
    type      = "EXPRESSION"
    values    = [tostring(var.session_duration)]
  }

  attribute_statements {
    name         = "https://aws.amazon.com/SAML/Attributes/Role"
    namespace    = "urn:oasis:names:tc:SAML:2.0:attrname-format:uri"
    type         = "GROUP"
    filter_type  = "STARTS_WITH"
    filter_value = var.okta_group_prefix
  }

  lifecycle {
    ignore_changes = [key_years_valid]
  }
}

# --- AWS SAML Identity Provider ---

resource "aws_iam_saml_provider" "okta" {
  name                   = var.saml_provider_name
  saml_metadata_document = okta_app_saml.aws.metadata

  tags = merge(local.common_tags, { Name = var.saml_provider_name })
}

# --- IAM Roles (one per role definition) ---

resource "aws_iam_role" "federated" {
  for_each = local.role_definitions

  name                 = each.value.name
  description          = each.value.description
  max_session_duration = var.session_duration
  permissions_boundary = each.value.permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRoleWithSAML"
      Principal = {
        Federated = aws_iam_saml_provider.okta.arn
      }
      Condition = {
        StringEquals = {
          "SAML:aud" = "https://signin.aws.amazon.com/saml"
        }
      }
    }]
  })

  tags = merge(local.common_tags, {
    Name      = each.value.name
    OktaGroup = "${var.okta_group_prefix}${each.value.name}"
  })
}

# --- Managed policy attachments (multiple policies per role) ---

resource "aws_iam_role_policy_attachment" "federated" {
  for_each = {
    for pair in flatten([
      for role_name, role in local.role_definitions : [
        for policy_arn in role.policy_arns : {
          key        = "${role_name}__${replace(basename(policy_arn), "/[^a-zA-Z0-9]/", "-")}"
          role_name  = role_name
          policy_arn = policy_arn
        }
      ]
    ]) : pair.key => pair
  }

  role       = aws_iam_role.federated[each.value.role_name].name
  policy_arn = each.value.policy_arn

  depends_on = [aws_iam_role.federated]
}

# --- Inline policies (optional, one per role) ---

resource "aws_iam_role_policy" "federated_inline" {
  for_each = {
    for name, role in local.role_definitions : name => role
    if role.inline_policy != null
  }

  name   = "${each.key}-inline"
  role   = aws_iam_role.federated[each.key].name
  policy = each.value.inline_policy
}

# --- Okta Groups (one per role, named with prefix) ---

resource "okta_group" "role_groups" {
  for_each    = local.role_definitions
  name        = "${var.okta_group_prefix}${each.value.name}"
  description = "AWS Federation: ${each.value.description}"
}

# --- Assign groups to the Okta SAML app ---
# Each group assignment carries the Role attribute value that Okta includes
# in the SAML assertion: "<role_arn>,<idp_arn>". AWS uses this to determine
# which IAM role to assume when the user signs in via SSO.

resource "okta_app_group_assignments" "aws" {
  app_id = okta_app_saml.aws.id

  dynamic "group" {
    for_each = local.role_definitions
    content {
      id = okta_group.role_groups[group.key].id
      profile = jsonencode({
        role      = "${aws_iam_role.federated[group.key].arn},${aws_iam_saml_provider.okta.arn}"
        samlRoles = ["${aws_iam_role.federated[group.key].arn},${aws_iam_saml_provider.okta.arn}"]
      })
    }
  }
}
