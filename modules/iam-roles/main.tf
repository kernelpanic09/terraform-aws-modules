###############################################################################
# locals
###############################################################################

locals {
  admin_role_name     = var.admin_role_name != "" ? var.admin_role_name : "${var.name_prefix}-admin"
  readonly_role_name  = var.readonly_role_name != "" ? var.readonly_role_name : "${var.name_prefix}-readonly"
  developer_role_name = var.developer_role_name != "" ? var.developer_role_name : "${var.name_prefix}-developer"
  cicd_role_name      = var.cicd_role_name != "" ? var.cicd_role_name : "${var.name_prefix}-cicd"

  # Effective permissions boundary per role (role-specific override wins)
  effective_cicd_boundary = var.cicd_permissions_boundary_arn != "" ? var.cicd_permissions_boundary_arn : var.permissions_boundary_arn

  # GitHub OIDC audience and thumbprint (stable values published by GitHub)
  github_oidc_url        = "https://token.actions.githubusercontent.com"
  github_oidc_thumbprint = "6938fd4d98bab03faadb97b34396831e3780aea1"

  # Build list of OIDC subject claims for GitHub Actions trust
  github_subjects = flatten([
    for repo in var.github_repositories : [
      for branch in var.github_branches : (
        branch == "*"
        ? "repo:${var.github_org}/${repo}:*"
        : "repo:${var.github_org}/${repo}:${branch}"
      )
    ]
  ])

  common_tags = merge(var.tags, {
    ManagedBy = "terraform"
    Module    = "iam-roles"
  })
}

###############################################################################
# Data: current account/partition for constructing ARNs
###############################################################################

data "aws_partition" "current" {}

###############################################################################
# GitHub Actions OIDC provider
###############################################################################

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_cicd_role && var.create_github_oidc_provider ? 1 : 0

  url             = local.github_oidc_url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [local.github_oidc_thumbprint]

  tags = local.common_tags
}

# Reference the OIDC provider whether we created it or it already existed
data "aws_iam_openid_connect_provider" "github" {
  count = var.create_cicd_role && !var.create_github_oidc_provider ? 1 : 0
  url   = local.github_oidc_url
}

locals {
  github_oidc_provider_arn = (
    var.create_cicd_role
    ? (
      var.create_github_oidc_provider
      ? aws_iam_openid_connect_provider.github[0].arn
      : data.aws_iam_openid_connect_provider.github[0].arn
    )
    : ""
  )
}

###############################################################################
# Admin role
###############################################################################

data "aws_iam_policy_document" "admin_trust" {
  count = var.create_admin_role ? 1 : 0

  dynamic "statement" {
    for_each = length(var.admin_trusted_account_ids) > 0 ? [1] : []
    content {
      sid     = "AllowAccountAssume"
      effect  = "Allow"
      actions = ["sts:AssumeRole"]

      principals {
        type = "AWS"
        identifiers = [
          for id in var.admin_trusted_account_ids :
          "arn:${data.aws_partition.current.partition}:iam::${id}:root"
        ]
      }

      dynamic "condition" {
        for_each = var.admin_require_mfa ? [1] : []
        content {
          test     = "Bool"
          variable = "aws:MultiFactorAuthPresent"
          values   = ["true"]
        }
      }
    }
  }

  dynamic "statement" {
    for_each = length(var.admin_trusted_saml_provider_arns) > 0 ? [1] : []
    content {
      sid     = "AllowSAMLFederation"
      effect  = "Allow"
      actions = ["sts:AssumeRoleWithSAML"]

      principals {
        type        = "Federated"
        identifiers = var.admin_trusted_saml_provider_arns
      }

      condition {
        test     = "StringEquals"
        variable = "SAML:aud"
        values   = ["https://signin.aws.amazon.com/saml"]
      }
    }
  }

  dynamic "statement" {
    for_each = var.admin_trusted_identity_center ? [1] : []
    content {
      sid     = "AllowIdentityCenter"
      effect  = "Allow"
      actions = ["sts:AssumeRole", "sts:SetSourceIdentity"]

      principals {
        type        = "Service"
        identifiers = ["sso.amazonaws.com"]
      }
    }
  }
}

resource "aws_iam_role" "admin" {
  count = var.create_admin_role ? 1 : 0

  name                 = local.admin_role_name
  description          = "Administrator role - full account access."
  assume_role_policy   = data.aws_iam_policy_document.admin_trust[0].json
  max_session_duration = var.admin_session_duration

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "admin_access" {
  count = var.create_admin_role ? 1 : 0

  role       = aws_iam_role.admin[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AdministratorAccess"
}

###############################################################################
# Read-only role
###############################################################################

data "aws_iam_policy_document" "readonly_trust" {
  count = var.create_readonly_role ? 1 : 0

  dynamic "statement" {
    for_each = length(var.readonly_trusted_account_ids) > 0 ? [1] : []
    content {
      sid     = "AllowAccountAssume"
      effect  = "Allow"
      actions = ["sts:AssumeRole"]

      principals {
        type = "AWS"
        identifiers = [
          for id in var.readonly_trusted_account_ids :
          "arn:${data.aws_partition.current.partition}:iam::${id}:root"
        ]
      }
    }
  }

  dynamic "statement" {
    for_each = var.readonly_trusted_identity_center ? [1] : []
    content {
      sid     = "AllowIdentityCenter"
      effect  = "Allow"
      actions = ["sts:AssumeRole", "sts:SetSourceIdentity"]

      principals {
        type        = "Service"
        identifiers = ["sso.amazonaws.com"]
      }
    }
  }
}

resource "aws_iam_role" "readonly" {
  count = var.create_readonly_role ? 1 : 0

  name                 = local.readonly_role_name
  description          = "Read-only role - ReadOnlyAccess + SecurityAudit."
  assume_role_policy   = data.aws_iam_policy_document.readonly_trust[0].json
  max_session_duration = var.readonly_session_duration

  permissions_boundary = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "readonly_access" {
  count = var.create_readonly_role ? 1 : 0

  role       = aws_iam_role.readonly[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy_attachment" "readonly_security_audit" {
  count = var.create_readonly_role ? 1 : 0

  role       = aws_iam_role.readonly[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/SecurityAudit"
}

###############################################################################
# Developer role
###############################################################################

data "aws_iam_policy_document" "developer_trust" {
  count = var.create_developer_role ? 1 : 0

  dynamic "statement" {
    for_each = length(var.developer_trusted_account_ids) > 0 ? [1] : []
    content {
      sid     = "AllowAccountAssume"
      effect  = "Allow"
      actions = ["sts:AssumeRole"]

      principals {
        type = "AWS"
        identifiers = [
          for id in var.developer_trusted_account_ids :
          "arn:${data.aws_partition.current.partition}:iam::${id}:root"
        ]
      }
    }
  }

  dynamic "statement" {
    for_each = var.developer_trusted_identity_center ? [1] : []
    content {
      sid     = "AllowIdentityCenter"
      effect  = "Allow"
      actions = ["sts:AssumeRole", "sts:SetSourceIdentity"]

      principals {
        type        = "Service"
        identifiers = ["sso.amazonaws.com"]
      }
    }
  }
}

data "aws_iam_policy_document" "developer_policy" {
  count = var.create_developer_role ? 1 : 0

  # ECS - full service management
  statement {
    sid    = "ECSFullAccess"
    effect = "Allow"
    actions = [
      "ecs:*",
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:DescribeRepositories",
      "ecr:ListImages",
      "ecr:DescribeImages",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:TagResource",
    ]
    resources = ["*"]
  }

  # S3 - scoped to configured buckets
  statement {
    sid    = "S3Access"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:GetBucketVersioning",
      "s3:ListBucketVersions",
      "s3:GetObjectVersion",
    ]
    resources = var.developer_allowed_s3_bucket_arns
  }

  # CloudWatch - logs and metrics
  statement {
    sid    = "CloudWatchAccess"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:GetLogEvents",
      "logs:FilterLogEvents",
      "logs:StartQuery",
      "logs:StopQuery",
      "logs:GetQueryResults",
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:PutMetricData",
    ]
    resources = ["*"]
  }

  # SSM - parameter store and session manager
  statement {
    sid    = "SSMAccess"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "ssm:PutParameter",
      "ssm:DescribeParameters",
      "ssm:StartSession",
      "ssm:TerminateSession",
      "ssm:DescribeSessions",
      "ssm:ResumeSession",
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }

  # Explicit deny on IAM and Organizations (prevents privilege escalation)
  statement {
    sid    = "DenyIAMAndOrganizations"
    effect = "Deny"
    actions = [
      "iam:CreateUser",
      "iam:DeleteUser",
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachUserPolicy",
      "iam:DetachUserPolicy",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:SetDefaultPolicyVersion",
      "iam:UpdateAssumeRolePolicy",
      "organizations:*",
    ]
    resources = ["*"]
  }

  # Read-only IAM (for awareness, not modification)
  statement {
    sid    = "IAMReadOnly"
    effect = "Allow"
    actions = [
      "iam:Get*",
      "iam:List*",
      "iam:GenerateCredentialReport",
      "iam:GenerateServiceLastAccessedDetails",
      "iam:SimulateCustomPolicy",
      "iam:SimulatePrincipalPolicy",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "developer" {
  count = var.create_developer_role ? 1 : 0

  name        = "${local.developer_role_name}-policy"
  description = "Custom policy for the ${local.developer_role_name} role - ECS, S3, CloudWatch, SSM, ECR access without IAM/Org write."
  policy      = data.aws_iam_policy_document.developer_policy[0].json

  tags = local.common_tags
}

resource "aws_iam_role" "developer" {
  count = var.create_developer_role ? 1 : 0

  name                 = local.developer_role_name
  description          = "Developer role - ECS, S3, CloudWatch, SSM, ECR. No IAM/Org writes."
  assume_role_policy   = data.aws_iam_policy_document.developer_trust[0].json
  max_session_duration = var.developer_session_duration

  permissions_boundary = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "developer_custom" {
  count = var.create_developer_role ? 1 : 0

  role       = aws_iam_role.developer[0].name
  policy_arn = aws_iam_policy.developer[0].arn
}

resource "aws_iam_role_policy_attachment" "developer_extra" {
  for_each = var.create_developer_role ? toset(var.developer_extra_policy_arns) : toset([])

  role       = aws_iam_role.developer[0].name
  policy_arn = each.value
}

###############################################################################
# CI/CD role (GitHub Actions OIDC)
###############################################################################

data "aws_iam_policy_document" "cicd_trust" {
  count = var.create_cicd_role ? 1 : 0

  statement {
    sid     = "GitHubOIDCAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.github_subjects
    }
  }
}

resource "aws_iam_role" "cicd" {
  count = var.create_cicd_role ? 1 : 0

  name                 = local.cicd_role_name
  description          = "CI/CD role for GitHub Actions OIDC - ${var.github_org}."
  assume_role_policy   = data.aws_iam_policy_document.cicd_trust[0].json
  max_session_duration = var.cicd_session_duration

  permissions_boundary = local.effective_cicd_boundary != "" ? local.effective_cicd_boundary : null

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "cicd_extra" {
  for_each = var.create_cicd_role ? toset(var.cicd_extra_policy_arns) : toset([])

  role       = aws_iam_role.cicd[0].name
  policy_arn = each.value
}
