###############################################################################
# locals
###############################################################################

locals {
  cloudtrail_name = var.cloudtrail_name != "" ? var.cloudtrail_name : "${var.name}-cloudtrail"

  state_bucket_name = "${var.name}-terraform-state-${data.aws_caller_identity.current.account_id}"
  lock_table_name   = "${var.name}-terraform-locks"
  cloudtrail_bucket = "${var.name}-cloudtrail-${data.aws_caller_identity.current.account_id}"
  config_bucket     = "${var.name}-config-${data.aws_caller_identity.current.account_id}"

  common_tags = merge(var.tags, {
    ManagedBy = "terraform"
    Module    = "landing-zone"
  })
}

###############################################################################
# Data sources
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

###############################################################################
# Terraform state backend - S3 bucket
###############################################################################

resource "aws_s3_bucket" "state" {
  count = var.enable_state_backend ? 1 : 0

  bucket        = local.state_bucket_name
  force_destroy = var.state_bucket_force_destroy

  tags = merge(local.common_tags, {
    Name    = local.state_bucket_name
    Purpose = "terraform-state"
  })
}

resource "aws_s3_bucket_versioning" "state" {
  count = var.enable_state_backend ? 1 : 0

  bucket = aws_s3_bucket.state[0].id

  versioning_configuration {
    status = var.state_bucket_versioning_enabled ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  count = var.enable_state_backend ? 1 : 0

  bucket = aws_s3_bucket.state[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  count = var.enable_state_backend ? 1 : 0

  bucket = aws_s3_bucket.state[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  count = var.enable_state_backend ? 1 : 0

  # Versioning must be enabled before applying lifecycle rules
  depends_on = [aws_s3_bucket_versioning.state]

  bucket = aws_s3_bucket.state[0].id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = var.state_bucket_lifecycle_noncurrent_days
    }

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "STANDARD_IA"
    }
  }

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "state_bucket_policy" {
  count = var.enable_state_backend ? 1 : 0

  # Deny any non-TLS access
  statement {
    sid     = "DenyNonTLS"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state[0].arn,
      "${aws_s3_bucket.state[0].arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Restrict access to the owning account only
  statement {
    sid     = "AllowOwnerAccountOnly"
    effect  = "Allow"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state[0].arn,
      "${aws_s3_bucket.state[0].arn}/*",
    ]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  count = var.enable_state_backend ? 1 : 0

  # Public access block must be in place before the bucket policy
  depends_on = [aws_s3_bucket_public_access_block.state]

  bucket = aws_s3_bucket.state[0].id
  policy = data.aws_iam_policy_document.state_bucket_policy[0].json
}

###############################################################################
# Terraform state backend - DynamoDB lock table
###############################################################################

resource "aws_dynamodb_table" "locks" {
  count = var.enable_state_backend ? 1 : 0

  name         = local.lock_table_name
  billing_mode = var.dynamodb_billing_mode
  hash_key     = "LockID"

  # Only set capacity when using PROVISIONED mode
  read_capacity  = var.dynamodb_billing_mode == "PROVISIONED" ? var.dynamodb_read_capacity : null
  write_capacity = var.dynamodb_billing_mode == "PROVISIONED" ? var.dynamodb_write_capacity : null

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = merge(local.common_tags, {
    Name    = local.lock_table_name
    Purpose = "terraform-locks"
  })
}

###############################################################################
# AWS Organizations
###############################################################################

resource "aws_organizations_organization" "this" {
  count = var.enable_organizations ? 1 : 0

  aws_service_access_principals = var.organizations_aws_service_access_principals
  enabled_policy_types          = var.organizations_enabled_policy_types
  feature_set                   = "ALL"
}

data "aws_organizations_organization" "current" {
  count = !var.enable_organizations ? 1 : 0
}

locals {
  org_id = var.enable_organizations ? aws_organizations_organization.this[0].id : (
    length(data.aws_organizations_organization.current) > 0 ? data.aws_organizations_organization.current[0].id : ""
  )
  org_root_id = var.enable_organizations ? aws_organizations_organization.this[0].roots[0].id : (
    length(data.aws_organizations_organization.current) > 0 ? data.aws_organizations_organization.current[0].roots[0].id : ""
  )
}

# SCP: deny leaving the organization
data "aws_iam_policy_document" "deny_leave_org" {
  count = var.enable_organizations && var.enable_scp_deny_leave_org ? 1 : 0

  statement {
    sid       = "DenyLeaveOrganization"
    effect    = "Deny"
    actions   = ["organizations:LeaveOrganization"]
    resources = ["*"]
  }
}

resource "aws_organizations_policy" "deny_leave_org" {
  count = var.enable_organizations && var.enable_scp_deny_leave_org ? 1 : 0

  name        = "${var.name}-deny-leave-org"
  description = "Prevents any account from calling LeaveOrganization."
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.deny_leave_org[0].json

  tags = local.common_tags
}

resource "aws_organizations_policy_attachment" "deny_leave_org" {
  count = var.enable_organizations && var.enable_scp_deny_leave_org ? 1 : 0

  policy_id = aws_organizations_policy.deny_leave_org[0].id
  target_id = local.org_root_id
}

###############################################################################
# KMS key for CloudTrail
###############################################################################

data "aws_iam_policy_document" "cloudtrail_kms" {
  count = var.enable_cloudtrail ? 1 : 0

  # Allow account root full key management
  statement {
    sid       = "EnableRootAccess"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  # Allow CloudTrail to use the key for encryption
  statement {
    sid       = "AllowCloudTrailEncrypt"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey*"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:${data.aws_partition.current.partition}:cloudtrail:*:${data.aws_caller_identity.current.account_id}:trail/*"]
    }
  }

  # Allow CloudTrail to describe the key
  statement {
    sid       = "AllowCloudTrailDescribe"
    effect    = "Allow"
    actions   = ["kms:DescribeKey"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }

  # Allow authorized IAM principals to decrypt log data
  statement {
    sid       = "AllowDecryptForAnalysis"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:ReEncryptFrom"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:${data.aws_partition.current.partition}:cloudtrail:*:${data.aws_caller_identity.current.account_id}:trail/*"]
    }
  }

  # Allow CloudWatch Logs to use the key
  statement {
    sid       = "AllowCloudWatchLogs"
    effect    = "Allow"
    actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.current.region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:*"]
    }
  }
}

resource "aws_kms_key" "cloudtrail" {
  count = var.enable_cloudtrail ? 1 : 0

  description             = "KMS key for ${local.cloudtrail_name} CloudTrail encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.cloudtrail_kms[0].json

  tags = merge(local.common_tags, {
    Name    = "${var.name}-cloudtrail-key"
    Purpose = "cloudtrail-encryption"
  })
}

resource "aws_kms_alias" "cloudtrail" {
  count = var.enable_cloudtrail ? 1 : 0

  name          = "alias/${var.name}-cloudtrail"
  target_key_id = aws_kms_key.cloudtrail[0].key_id
}

###############################################################################
# CloudTrail S3 bucket
###############################################################################

data "aws_iam_policy_document" "cloudtrail_bucket_policy" {
  count = var.enable_cloudtrail ? 1 : 0

  statement {
    sid       = "AWSCloudTrailAclCheck"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.cloudtrail[0].arn]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:cloudtrail:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:trail/${local.cloudtrail_name}"]
    }
  }

  statement {
    sid     = "AWSCloudTrailWrite"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.cloudtrail[0].arn}/${var.cloudtrail_s3_key_prefix}/AWSLogs/${data.aws_caller_identity.current.account_id}/*",
    ]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:cloudtrail:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:trail/${local.cloudtrail_name}"]
    }
  }

  # Organization trail: also allow delivery for all member accounts
  dynamic "statement" {
    for_each = var.cloudtrail_is_organization_trail ? [1] : []
    content {
      sid     = "AWSCloudTrailOrganizationWrite"
      effect  = "Allow"
      actions = ["s3:PutObject"]
      resources = [
        "${aws_s3_bucket.cloudtrail[0].arn}/${var.cloudtrail_s3_key_prefix}/AWSLogs/${local.org_id}/*",
      ]

      principals {
        type        = "Service"
        identifiers = ["cloudtrail.amazonaws.com"]
      }

      condition {
        test     = "StringEquals"
        variable = "s3:x-amz-acl"
        values   = ["bucket-owner-full-control"]
      }
    }
  }

  # Deny non-TLS
  statement {
    sid     = "DenyNonTLS"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.cloudtrail[0].arn,
      "${aws_s3_bucket.cloudtrail[0].arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket" "cloudtrail" {
  count = var.enable_cloudtrail ? 1 : 0

  bucket        = local.cloudtrail_bucket
  force_destroy = false

  tags = merge(local.common_tags, {
    Name    = local.cloudtrail_bucket
    Purpose = "cloudtrail-logs"
  })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  count = var.enable_cloudtrail ? 1 : 0

  bucket = aws_s3_bucket.cloudtrail[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.cloudtrail[0].arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  count = var.enable_cloudtrail ? 1 : 0

  bucket = aws_s3_bucket.cloudtrail[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "cloudtrail" {
  count = var.enable_cloudtrail ? 1 : 0

  bucket = aws_s3_bucket.cloudtrail[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  count = var.enable_cloudtrail ? 1 : 0

  depends_on = [aws_s3_bucket_versioning.cloudtrail]

  bucket = aws_s3_bucket.cloudtrail[0].id

  rule {
    id     = "transition-and-expire"
    status = "Enabled"

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 365
      storage_class = "GLACIER"
    }

    expiration {
      days = 2557 # 7 years - common compliance requirement
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  count = var.enable_cloudtrail ? 1 : 0

  depends_on = [aws_s3_bucket_public_access_block.cloudtrail]

  bucket = aws_s3_bucket.cloudtrail[0].id
  policy = data.aws_iam_policy_document.cloudtrail_bucket_policy[0].json
}

###############################################################################
# CloudTrail - CloudWatch Logs
###############################################################################

resource "aws_cloudwatch_log_group" "cloudtrail" {
  count = var.enable_cloudtrail && var.cloudtrail_log_retention_days > 0 ? 1 : 0

  name              = "/aws/cloudtrail/${local.cloudtrail_name}"
  retention_in_days = var.cloudtrail_log_retention_days
  kms_key_id        = aws_kms_key.cloudtrail[0].arn

  tags = local.common_tags
}

data "aws_iam_policy_document" "cloudtrail_cloudwatch_assume" {
  count = var.enable_cloudtrail && var.cloudtrail_log_retention_days > 0 ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "cloudtrail_cloudwatch_policy" {
  count = var.enable_cloudtrail && var.cloudtrail_log_retention_days > 0 ? 1 : 0

  statement {
    sid    = "AWSCloudTrailCreateLogStream"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.cloudtrail[0].arn}:*"]
  }
}

resource "aws_iam_role" "cloudtrail_cloudwatch" {
  count = var.enable_cloudtrail && var.cloudtrail_log_retention_days > 0 ? 1 : 0

  name               = "${var.name}-cloudtrail-cw-role"
  assume_role_policy = data.aws_iam_policy_document.cloudtrail_cloudwatch_assume[0].json

  tags = local.common_tags
}

resource "aws_iam_role_policy" "cloudtrail_cloudwatch" {
  count = var.enable_cloudtrail && var.cloudtrail_log_retention_days > 0 ? 1 : 0

  name   = "${var.name}-cloudtrail-cw-policy"
  role   = aws_iam_role.cloudtrail_cloudwatch[0].id
  policy = data.aws_iam_policy_document.cloudtrail_cloudwatch_policy[0].json
}

###############################################################################
# CloudTrail trail
###############################################################################

resource "aws_cloudtrail" "this" {
  count = var.enable_cloudtrail ? 1 : 0

  depends_on = [aws_s3_bucket_policy.cloudtrail]

  name                          = local.cloudtrail_name
  s3_bucket_name                = aws_s3_bucket.cloudtrail[0].id
  s3_key_prefix                 = var.cloudtrail_s3_key_prefix
  kms_key_id                    = aws_kms_key.cloudtrail[0].arn
  is_multi_region_trail         = true
  is_organization_trail         = var.cloudtrail_is_organization_trail
  include_global_service_events = var.cloudtrail_include_global_service_events
  enable_log_file_validation    = var.cloudtrail_enable_log_file_validation
  enable_logging                = true

  cloud_watch_logs_group_arn = (
    var.cloudtrail_log_retention_days > 0
    ? "${aws_cloudwatch_log_group.cloudtrail[0].arn}:*"
    : null
  )
  cloud_watch_logs_role_arn = (
    var.cloudtrail_log_retention_days > 0
    ? aws_iam_role.cloudtrail_cloudwatch[0].arn
    : null
  )

  tags = local.common_tags
}

###############################################################################
# AWS Config
###############################################################################

data "aws_iam_policy_document" "config_assume" {
  count = var.enable_config ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "config" {
  count = var.enable_config ? 1 : 0

  name               = "${var.name}-config-role"
  assume_role_policy = data.aws_iam_policy_document.config_assume[0].json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "config_managed" {
  count = var.enable_config ? 1 : 0

  role       = aws_iam_role.config[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_s3_bucket" "config" {
  count = var.enable_config ? 1 : 0

  bucket        = local.config_bucket
  force_destroy = false

  tags = merge(local.common_tags, {
    Name    = local.config_bucket
    Purpose = "config-snapshots"
  })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  count = var.enable_config ? 1 : 0

  bucket = aws_s3_bucket.config[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  count = var.enable_config ? 1 : 0

  bucket = aws_s3_bucket.config[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "config_bucket_policy" {
  count = var.enable_config ? 1 : 0

  statement {
    sid       = "AWSConfigBucketPermissionsCheck"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.config[0].arn]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
  }

  statement {
    sid       = "AWSConfigBucketDelivery"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.config[0].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*"]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "config" {
  count = var.enable_config ? 1 : 0

  depends_on = [aws_s3_bucket_public_access_block.config]

  bucket = aws_s3_bucket.config[0].id
  policy = data.aws_iam_policy_document.config_bucket_policy[0].json
}

resource "aws_config_configuration_recorder" "this" {
  count = var.enable_config ? 1 : 0

  name     = "${var.name}-config-recorder"
  role_arn = aws_iam_role.config[0].arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = var.config_include_global_resource_types
  }
}

resource "aws_config_delivery_channel" "this" {
  count = var.enable_config ? 1 : 0

  depends_on = [aws_config_configuration_recorder.this]

  name           = "${var.name}-config-channel"
  s3_bucket_name = aws_s3_bucket.config[0].id

  snapshot_delivery_properties {
    delivery_frequency = var.config_delivery_frequency
  }
}

resource "aws_config_configuration_recorder_status" "this" {
  count = var.enable_config ? 1 : 0

  depends_on = [aws_config_delivery_channel.this]

  name       = aws_config_configuration_recorder.this[0].name
  is_enabled = true
}

###############################################################################
# Budget alarm
###############################################################################

resource "aws_sns_topic" "budget" {
  count = var.enable_budget_alarm ? 1 : 0

  name = "${var.name}-budget-alerts"

  tags = local.common_tags
}

resource "aws_sns_topic_subscription" "budget_email" {
  for_each = var.enable_budget_alarm ? toset(var.budget_alert_email_addresses) : toset([])

  topic_arn = aws_sns_topic.budget[0].arn
  protocol  = "email"
  endpoint  = each.value
}

data "aws_iam_policy_document" "budget_sns_policy" {
  count = var.enable_budget_alarm ? 1 : 0

  statement {
    sid       = "AllowBudgetsPublish"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.budget[0].arn]

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }
  }
}

resource "aws_sns_topic_policy" "budget" {
  count = var.enable_budget_alarm ? 1 : 0

  arn    = aws_sns_topic.budget[0].arn
  policy = data.aws_iam_policy_document.budget_sns_policy[0].json
}

resource "aws_budgets_budget" "monthly" {
  count = var.enable_budget_alarm ? 1 : 0

  name         = "${var.name}-monthly-budget"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_amount)
  limit_unit   = "USD"
  time_unit    = var.budget_time_unit

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = var.budget_alert_threshold_percent
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget[0].arn]
  }

  # Also alert on forecasted overage
  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = var.budget_alert_threshold_percent
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.budget[0].arn]
  }
}
