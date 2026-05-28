data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name
  common_tags = merge(var.tags, { ManagedBy = "terraform", Module = "incident-response" })
}

# ------------------------------------------------------------------------------
# GuardDuty
# ------------------------------------------------------------------------------

resource "aws_guardduty_detector" "this" {
  enable = true

  datasources {
    s3_logs {
      enable = var.enable_s3_protection
    }
    kubernetes {
      audit_logs {
        enable = var.enable_k8s_protection
      }
    }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          enable = var.enable_malware_protection
        }
      }
    }
  }

  finding_publishing_frequency = var.finding_publishing_frequency

  tags = merge(local.common_tags, { Name = "${var.name}-guardduty" })
}

# ------------------------------------------------------------------------------
# Security Hub
# ------------------------------------------------------------------------------

resource "aws_securityhub_account" "this" {
  count                    = var.enable_security_hub ? 1 : 0
  enable_default_standards = false
}

resource "aws_securityhub_standards_subscription" "cis" {
  count         = var.enable_security_hub ? 1 : 0
  standards_arn = "arn:aws:securityhub:${local.region}::standards/cis-aws-foundations-benchmark/v/1.4.0"
  depends_on    = [aws_securityhub_account.this]
}

resource "aws_securityhub_standards_subscription" "foundational" {
  count         = var.enable_security_hub ? 1 : 0
  standards_arn = "arn:aws:securityhub:${local.region}::standards/aws-foundational-security-best-practices/v/1.0.0"
  depends_on    = [aws_securityhub_account.this]
}

resource "aws_securityhub_product_subscription" "guardduty" {
  count       = var.enable_security_hub ? 1 : 0
  product_arn = "arn:aws:securityhub:${local.region}::product/aws/guardduty"
  depends_on  = [aws_securityhub_account.this]
}

# ------------------------------------------------------------------------------
# KMS key for SNS encryption
# ------------------------------------------------------------------------------

resource "aws_kms_key" "sns" {
  description             = "Encryption key for incident response SNS topics"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowAccountRoot"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowEventBridgeAndSNS"
        Effect    = "Allow"
        Principal = { Service = ["events.amazonaws.com", "sns.amazonaws.com"] }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey*"]
        Resource  = "*"
      }
    ]
  })

  tags = merge(local.common_tags, { Name = "${var.name}-incident-sns-key" })
}

resource "aws_kms_alias" "sns" {
  name          = "alias/${var.name}-incident-sns"
  target_key_id = aws_kms_key.sns.key_id
}

# ------------------------------------------------------------------------------
# SNS topics
# ------------------------------------------------------------------------------

resource "aws_sns_topic" "high_severity" {
  name              = "${var.name}-security-high"
  kms_master_key_id = aws_kms_key.sns.id
  tags              = merge(local.common_tags, { Severity = "high" })
}

resource "aws_sns_topic" "medium_severity" {
  name              = "${var.name}-security-medium"
  kms_master_key_id = aws_kms_key.sns.id
  tags              = merge(local.common_tags, { Severity = "medium" })
}

resource "aws_sns_topic_subscription" "high_email" {
  for_each  = toset(var.alert_emails)
  topic_arn = aws_sns_topic.high_severity.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_sns_topic_subscription" "medium_email" {
  for_each  = toset(var.alert_emails)
  topic_arn = aws_sns_topic.medium_severity.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_sns_topic_policy" "high" {
  arn = aws_sns_topic.high_severity.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridgePublish"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "SNS:Publish"
      Resource  = aws_sns_topic.high_severity.arn
    }]
  })
}

resource "aws_sns_topic_policy" "medium" {
  arn = aws_sns_topic.medium_severity.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridgePublish"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "SNS:Publish"
      Resource  = aws_sns_topic.medium_severity.arn
    }]
  })
}

# ------------------------------------------------------------------------------
# EventBridge rules
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "high_severity" {
  name        = "${var.name}-guardduty-high"
  description = "Capture GuardDuty findings with severity >= 7 (HIGH and CRITICAL)"

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", 7] }]
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_rule" "medium_severity" {
  name        = "${var.name}-guardduty-medium"
  description = "Capture GuardDuty findings with severity >= 4 and < 7 (MEDIUM)"

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", 4, "<", 7] }]
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "high_sns" {
  rule      = aws_cloudwatch_event_rule.high_severity.name
  target_id = "high-severity-sns"
  arn       = aws_sns_topic.high_severity.arn
}

resource "aws_cloudwatch_event_target" "medium_sns" {
  rule      = aws_cloudwatch_event_rule.medium_severity.name
  target_id = "medium-severity-sns"
  arn       = aws_sns_topic.medium_severity.arn
}

# Route high-severity findings to Lambda only when auto-remediation is enabled.
resource "aws_cloudwatch_event_target" "high_lambda" {
  count     = var.enable_auto_remediation ? 1 : 0
  rule      = aws_cloudwatch_event_rule.high_severity.name
  target_id = "auto-remediation"
  arn       = aws_lambda_function.remediation[0].arn
}

# ------------------------------------------------------------------------------
# Auto-remediation Lambda
# ------------------------------------------------------------------------------

data "archive_file" "remediation" {
  count       = var.enable_auto_remediation ? 1 : 0
  type        = "zip"
  output_path = "${path.module}/lambda/remediation.zip"

  source {
    content  = <<-PYTHON
import json
import boto3
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

iam        = boto3.client('iam')
ec2        = boto3.client('ec2')
s3_client  = boto3.client('s3')


def handler(event, context):
    detail       = event.get('detail', {})
    finding_type = detail.get('type', '')
    severity     = detail.get('severity', 0)

    logger.info(json.dumps({
        "message":      "processing_finding",
        "finding_type": finding_type,
        "severity":     severity,
    }))

    try:
        if 'UnauthorizedAccess:IAMUser' in finding_type or 'CredentialAccess' in finding_type:
            remediate_compromised_credentials(detail)
        elif 'Policy:S3/BucketPublicAccessGranted' in finding_type or 'S3/BucketAnonymousAccessGranted' in finding_type:
            remediate_public_s3(detail)
        elif 'UnauthorizedAccess:EC2/OpenSG' in finding_type:
            remediate_open_security_group(detail)
        else:
            logger.info(json.dumps({
                "message":      "no_remediation_defined",
                "finding_type": finding_type,
            }))
    except Exception as exc:
        logger.error(json.dumps({
            "message":      "remediation_failed",
            "finding_type": finding_type,
            "error":        str(exc),
        }))
        raise

    return {'statusCode': 200, 'finding_type': finding_type}


def remediate_compromised_credentials(detail):
    """Disable the IAM access key referenced in the finding."""
    resource         = detail.get('resource', {})
    key_details      = resource.get('accessKeyDetails', {})
    user_name        = key_details.get('userName', '')
    access_key_id    = key_details.get('accessKeyId', '')

    if not (user_name and access_key_id):
        logger.warning("remediate_compromised_credentials: missing userName or accessKeyId, skipping")
        return

    logger.info(json.dumps({
        "message":       "disabling_access_key",
        "user_name":     user_name,
        "access_key_id": access_key_id,
    }))
    iam.update_access_key(
        UserName=user_name,
        AccessKeyId=access_key_id,
        Status='Inactive',
    )


def remediate_public_s3(detail):
    """Apply full public-access block to the S3 bucket referenced in the finding."""
    resource    = detail.get('resource', {})
    bucket_list = resource.get('s3BucketDetails', [])
    bucket_name = bucket_list[0].get('name', '') if bucket_list else ''

    if not bucket_name:
        logger.warning("remediate_public_s3: missing bucket name, skipping")
        return

    logger.info(json.dumps({
        "message":     "blocking_public_access",
        "bucket_name": bucket_name,
    }))
    s3_client.put_public_access_block(
        Bucket=bucket_name,
        PublicAccessBlockConfiguration={
            'BlockPublicAcls':       True,
            'IgnorePublicAcls':      True,
            'BlockPublicPolicy':     True,
            'RestrictPublicBuckets': True,
        },
    )


def remediate_open_security_group(detail):
    """Revoke all 0.0.0.0/0 ingress rules from the security group referenced in the finding."""
    resource    = detail.get('resource', {})
    interfaces  = resource.get('instanceDetails', {}).get('networkInterfaces', [])
    sg_list     = interfaces[0].get('securityGroups', []) if interfaces else []
    sg_id       = sg_list[0].get('groupId', '') if sg_list else ''

    if not sg_id:
        logger.warning("remediate_open_security_group: missing security group ID, skipping")
        return

    logger.info(json.dumps({
        "message": "revoking_open_sg_ingress",
        "sg_id":   sg_id,
    }))

    sg_response = ec2.describe_security_groups(GroupIds=[sg_id])
    ip_permissions = sg_response['SecurityGroups'][0].get('IpPermissions', [])

    rules_to_revoke = []
    for rule in ip_permissions:
        # Remove only the specific CidrIp entry, not the entire rule, to avoid
        # revoking legitimate peer-restricted rules on the same port/protocol.
        open_ranges = [r for r in rule.get('IpRanges', []) if r.get('CidrIp') == '0.0.0.0/0']
        open_ipv6   = [r for r in rule.get('Ipv6Ranges', []) if r.get('CidrIpv6') == '::/0']
        if open_ranges or open_ipv6:
            scoped_rule = {k: v for k, v in rule.items() if k not in ('IpRanges', 'Ipv6Ranges')}
            if open_ranges:
                scoped_rule['IpRanges']  = open_ranges
            if open_ipv6:
                scoped_rule['Ipv6Ranges'] = open_ipv6
            rules_to_revoke.append(scoped_rule)

    if rules_to_revoke:
        ec2.revoke_security_group_ingress(GroupId=sg_id, IpPermissions=rules_to_revoke)
        logger.info(json.dumps({
            "message":       "revoked_sg_rules",
            "sg_id":         sg_id,
            "rules_revoked": len(rules_to_revoke),
        }))
    PYTHON
    filename = "index.py"
  }
}

resource "aws_lambda_function" "remediation" {
  count = var.enable_auto_remediation ? 1 : 0

  function_name    = "${var.name}-security-remediation"
  description      = "Auto-remediates common GuardDuty findings: disables compromised IAM keys, blocks public S3 access, and revokes unrestricted security group ingress"
  runtime          = "python3.12"
  handler          = "index.handler"
  timeout          = 60
  memory_size      = 128
  filename         = data.archive_file.remediation[0].output_path
  source_code_hash = data.archive_file.remediation[0].output_base64sha256
  role             = aws_iam_role.remediation[0].arn

  environment {
    variables = {
      LOG_LEVEL = "INFO"
    }
  }

  tags = merge(local.common_tags, { Name = "${var.name}-security-remediation" })
}

resource "aws_lambda_permission" "eventbridge" {
  count         = var.enable_auto_remediation ? 1 : 0
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediation[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.high_severity.arn
}

# ------------------------------------------------------------------------------
# IAM role for Lambda
# ------------------------------------------------------------------------------

resource "aws_iam_role" "remediation" {
  count       = var.enable_auto_remediation ? 1 : 0
  name        = "${var.name}-security-remediation"
  description = "Execution role for the incident-response auto-remediation Lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "remediation" {
  count = var.enable_auto_remediation ? 1 : 0
  name  = "${var.name}-security-remediation"
  role  = aws_iam_role.remediation[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${local.region}:${local.account_id}:*"
      },
      {
        Sid    = "IAMRemediation"
        Effect = "Allow"
        Action = [
          "iam:UpdateAccessKey",
          "iam:ListAccessKeys",
        ]
        # Scoped to IAM users only; cannot scope further without knowing usernames at plan time.
        Resource = "arn:aws:iam::${local.account_id}:user/*"
      },
      {
        Sid    = "S3Remediation"
        Effect = "Allow"
        Action = [
          "s3:PutBucketPublicAccessBlock",
          "s3:GetBucketPublicAccessBlock",
        ]
        # S3 bucket ARNs are not known at plan time; bucket name comes from the GuardDuty finding.
        Resource = "*"
      },
      {
        Sid    = "EC2Remediation"
        Effect = "Allow"
        Action = [
          "ec2:DescribeSecurityGroups",
          "ec2:RevokeSecurityGroupIngress",
        ]
        # EC2 describe APIs do not support resource-level restrictions.
        Resource = "*"
      },
    ]
  })
}

# ------------------------------------------------------------------------------
# CloudWatch alarm on Lambda errors
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  count = var.enable_auto_remediation ? 1 : 0

  alarm_name          = "${var.name}-remediation-errors"
  alarm_description   = "Fires when the security auto-remediation Lambda records one or more errors in a 5-minute window. Alerts on the high-severity SNS topic."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.remediation[0].function_name
  }

  alarm_actions = [aws_sns_topic.high_severity.arn]

  tags = local.common_tags
}
