# ---------------------------------------------------------------------------
# route53-failover module
#
# Implements active-passive multi-region DNS failover using Route53 failover
# routing policy, health checks, CloudWatch alarms, SNS notifications, and
# an optional EventBridge rule for health state change events.
#
# IMPORTANT: Route53 CloudWatch metrics are ALWAYS published to us-east-1.
# The module requires a provider alias "aws.us_east_1" for alarm resources.
# ---------------------------------------------------------------------------

locals {
  name_prefix = replace(var.domain_name, ".", "-")

  common_tags = merge(
    {
      "ManagedBy" = "terraform"
      "Module"    = "route53-failover"
      "Domain"    = var.domain_name
    },
    var.tags
  )

  # Paths are not applicable for TCP health checks.
  primary_use_path   = var.primary_endpoint.type != "TCP"
  secondary_use_path = var.secondary_endpoint.type != "TCP"
}

# ---------------------------------------------------------------------------
# Health checks
# ---------------------------------------------------------------------------

resource "aws_route53_health_check" "primary" {
  # Use FQDN if provided (enables SNI for HTTPS); otherwise use IP address.
  # When both ip_address and fqdn are omitted, Route53 uses fqdn for DNS resolution
  # before probing. Setting fqdn with an ip_address sends the Host header correctly.
  ip_address        = var.primary_endpoint.fqdn == null ? var.primary_endpoint.address : null
  fqdn              = var.primary_endpoint.fqdn
  type              = var.primary_endpoint.type
  port              = var.primary_endpoint.port
  resource_path     = local.primary_use_path ? var.primary_endpoint.path : null
  search_string     = can(regex("STR_MATCH", var.primary_endpoint.type)) ? var.primary_endpoint.search_string : null
  request_interval  = var.request_interval
  failure_threshold = var.failure_threshold
  measure_latency   = var.measure_latency

  # Route53 probes from these regions. A majority must agree the endpoint is
  # down before the health check transitions to unhealthy.
  regions = var.health_check_regions

  # CloudWatch metrics for Route53 health checks are automatically published
  # to us-east-1. No attribute is required here. the metrics appear under
  # the AWS/Route53 namespace with the HealthCheckId dimension.

  tags = merge(local.common_tags, {
    "Name"     = "${local.name_prefix}-primary-hc"
    "Endpoint" = coalesce(var.primary_endpoint.fqdn, var.primary_endpoint.address)
    "Role"     = "primary"
  })
}

resource "aws_route53_health_check" "secondary" {
  ip_address        = var.secondary_endpoint.fqdn == null ? var.secondary_endpoint.address : null
  fqdn              = var.secondary_endpoint.fqdn
  type              = var.secondary_endpoint.type
  port              = var.secondary_endpoint.port
  resource_path     = local.secondary_use_path ? var.secondary_endpoint.path : null
  search_string     = can(regex("STR_MATCH", var.secondary_endpoint.type)) ? var.secondary_endpoint.search_string : null
  request_interval  = var.request_interval
  failure_threshold = var.failure_threshold
  measure_latency   = var.measure_latency
  regions           = var.health_check_regions

  tags = merge(local.common_tags, {
    "Name"     = "${local.name_prefix}-secondary-hc"
    "Endpoint" = coalesce(var.secondary_endpoint.fqdn, var.secondary_endpoint.address)
    "Role"     = "secondary"
  })
}

# Calculated health check. optional. Aggregates primary + secondary into a
# single health check resource useful for dashboards and escalation alarms.
resource "aws_route53_health_check" "calculated" {
  count = var.enable_calculated_health_check ? 1 : 0

  type                   = "CALCULATED"
  child_health_threshold = var.calculated_health_check_threshold

  child_healthchecks = [
    aws_route53_health_check.primary.id,
    aws_route53_health_check.secondary.id,
  ]

  tags = merge(local.common_tags, {
    "Name" = "${local.name_prefix}-calculated-hc"
    "Role" = "aggregated"
  })
}

# ---------------------------------------------------------------------------
# Route53 DNS records. A (and optionally AAAA)
# ---------------------------------------------------------------------------

# Primary A record (active)
resource "aws_route53_record" "primary_a" {
  zone_id        = var.hosted_zone_id
  name           = var.record_name
  type           = var.record_type
  ttl            = var.record_ttl
  records        = [var.primary_endpoint.address]
  set_identifier = "primary"

  failover_routing_policy {
    type = "PRIMARY"
  }

  health_check_id = aws_route53_health_check.primary.id
}

# Secondary A record (passive failover target)
resource "aws_route53_record" "secondary_a" {
  zone_id        = var.hosted_zone_id
  name           = var.record_name
  type           = var.record_type
  ttl            = var.record_ttl
  records        = [var.secondary_endpoint.address]
  set_identifier = "secondary"

  failover_routing_policy {
    type = "SECONDARY"
  }

  # The secondary health check gates fail-back: Route53 will only return to
  # serving the primary after the primary recovers AND will continue using the
  # secondary as long as it is healthy. If you want the secondary to always
  # serve traffic regardless of its own health status (last-resort behavior),
  # remove this attribute. Removing it is appropriate when the secondary is a
  # static maintenance page or a guaranteed-available fallback.
  health_check_id = aws_route53_health_check.secondary.id
}

# Primary AAAA record (active, dual-stack)
resource "aws_route53_record" "primary_aaaa" {
  count = var.enable_ipv6 ? 1 : 0

  zone_id        = var.hosted_zone_id
  name           = var.record_name
  type           = "AAAA"
  ttl            = var.record_ttl
  records        = [var.primary_ipv6_address]
  set_identifier = "primary-ipv6"

  failover_routing_policy {
    type = "PRIMARY"
  }

  health_check_id = aws_route53_health_check.primary.id
}

# Secondary AAAA record (passive failover target, dual-stack)
resource "aws_route53_record" "secondary_aaaa" {
  count = var.enable_ipv6 ? 1 : 0

  zone_id        = var.hosted_zone_id
  name           = var.record_name
  type           = "AAAA"
  ttl            = var.record_ttl
  records        = [var.secondary_ipv6_address]
  set_identifier = "secondary-ipv6"

  failover_routing_policy {
    type = "SECONDARY"
  }

  health_check_id = aws_route53_health_check.secondary.id
}

# ---------------------------------------------------------------------------
# SNS topic for notifications (us-east-1. co-located with CloudWatch alarms)
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "failover" {
  count    = var.enable_alarms ? 1 : 0
  provider = aws.us_east_1

  name = "${local.name_prefix}-route53-failover"

  tags = merge(local.common_tags, {
    "Name" = "${local.name_prefix}-route53-failover"
  })
}

resource "aws_sns_topic_subscription" "email" {
  count    = var.enable_alarms ? length(var.alarm_emails) : 0
  provider = aws.us_east_1

  topic_arn = aws_sns_topic.failover[0].arn
  protocol  = "email"
  endpoint  = var.alarm_emails[count.index]
}

# ---------------------------------------------------------------------------
# CloudWatch alarms (must be in us-east-1. Route53 hardcodes metrics there)
# ---------------------------------------------------------------------------

# Alarm: primary endpoint health check failed
resource "aws_cloudwatch_metric_alarm" "primary_health_check" {
  count    = var.enable_alarms ? 1 : 0
  provider = aws.us_east_1

  alarm_name          = "${local.name_prefix}-primary-health-check-failed"
  alarm_description   = "Route53 health check for the primary endpoint (${coalesce(var.primary_endpoint.fqdn, var.primary_endpoint.address)}) has failed. DNS failover to the secondary endpoint is active or imminent."
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  evaluation_periods  = var.alarm_evaluation_periods
  datapoints_to_alarm = var.alarm_evaluation_periods

  namespace   = "AWS/Route53"
  metric_name = "HealthCheckStatus"
  period      = 60
  statistic   = "Minimum"

  dimensions = {
    HealthCheckId = aws_route53_health_check.primary.id
  }

  alarm_actions = [aws_sns_topic.failover[0].arn]
  ok_actions    = [aws_sns_topic.failover[0].arn]

  treat_missing_data = "breaching"

  tags = merge(local.common_tags, {
    "Name" = "${local.name_prefix}-primary-health-check-failed"
    "Role" = "primary-alarm"
  })
}

# Alarm: secondary endpoint health check failed (warning. not yet a full outage)
resource "aws_cloudwatch_metric_alarm" "secondary_health_check" {
  count    = var.enable_alarms ? 1 : 0
  provider = aws.us_east_1

  alarm_name          = "${local.name_prefix}-secondary-health-check-failed"
  alarm_description   = "Route53 health check for the secondary endpoint (${coalesce(var.secondary_endpoint.fqdn, var.secondary_endpoint.address)}) has failed. If the primary also fails, a total outage will occur."
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  evaluation_periods  = var.alarm_evaluation_periods
  datapoints_to_alarm = var.alarm_evaluation_periods

  namespace   = "AWS/Route53"
  metric_name = "HealthCheckStatus"
  period      = 60
  statistic   = "Minimum"

  dimensions = {
    HealthCheckId = aws_route53_health_check.secondary.id
  }

  alarm_actions = [aws_sns_topic.failover[0].arn]
  ok_actions    = [aws_sns_topic.failover[0].arn]

  treat_missing_data = "breaching"

  tags = merge(local.common_tags, {
    "Name" = "${local.name_prefix}-secondary-health-check-failed"
    "Role" = "secondary-alarm"
  })
}

# Alarm: latency p99 exceeds threshold for primary (only when measure_latency = true)
resource "aws_cloudwatch_metric_alarm" "primary_latency" {
  count    = var.enable_alarms && var.measure_latency ? 1 : 0
  provider = aws.us_east_1

  alarm_name          = "${local.name_prefix}-primary-latency-high"
  alarm_description   = "Route53 measured latency for the primary health check is elevated (p99 > 3000ms). This may indicate regional degradation before a full health check failure."
  comparison_operator = "GreaterThanThreshold"
  threshold           = 3000
  evaluation_periods  = 3
  datapoints_to_alarm = 2

  namespace          = "AWS/Route53"
  metric_name        = "TimeToFirstByte"
  period             = 60
  extended_statistic = "p99"

  dimensions = {
    HealthCheckId = aws_route53_health_check.primary.id
  }

  alarm_actions = [aws_sns_topic.failover[0].arn]

  treat_missing_data = "notBreaching"

  tags = merge(local.common_tags, {
    "Name" = "${local.name_prefix}-primary-latency-high"
    "Role" = "primary-latency-alarm"
  })
}

# Composite alarm: both endpoints down (total outage escalation)
resource "aws_cloudwatch_composite_alarm" "both_endpoints_down" {
  count    = var.enable_alarms && var.enable_composite_alarm ? 1 : 0
  provider = aws.us_east_1

  alarm_name        = "${local.name_prefix}-both-endpoints-down"
  alarm_description = "CRITICAL: Both the primary and secondary endpoints are unhealthy. DNS failover cannot succeed and the service is experiencing a total outage. Immediate intervention required."

  alarm_rule = "ALARM(\"${aws_cloudwatch_metric_alarm.primary_health_check[0].alarm_name}\") AND ALARM(\"${aws_cloudwatch_metric_alarm.secondary_health_check[0].alarm_name}\")"

  alarm_actions = [aws_sns_topic.failover[0].arn]
  ok_actions    = [aws_sns_topic.failover[0].arn]

  tags = merge(local.common_tags, {
    "Name"     = "${local.name_prefix}-both-endpoints-down"
    "Role"     = "composite-escalation-alarm"
    "Severity" = "critical"
  })
}

# ---------------------------------------------------------------------------
# EventBridge rule: Route53 health check state changes -> SNS
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "health_check_state_change" {
  count    = var.enable_alarms && var.enable_eventbridge_rule ? 1 : 0
  provider = aws.us_east_1

  name        = "${local.name_prefix}-r53-health-state-change"
  description = "Capture Route53 health check state change events for ${var.domain_name} and forward to SNS."

  event_pattern = jsonencode({
    source      = ["aws.route53"]
    detail-type = ["Route53 Health Check Status Changed"]
    detail = {
      healthCheckId = [
        aws_route53_health_check.primary.id,
        aws_route53_health_check.secondary.id,
      ]
    }
  })

  tags = merge(local.common_tags, {
    "Name" = "${local.name_prefix}-r53-health-state-change"
  })
}

resource "aws_cloudwatch_event_target" "health_check_state_change_sns" {
  count    = var.enable_alarms && var.enable_eventbridge_rule ? 1 : 0
  provider = aws.us_east_1

  rule      = aws_cloudwatch_event_rule.health_check_state_change[0].name
  target_id = "SendToSNS"
  arn       = aws_sns_topic.failover[0].arn

  input_transformer {
    input_paths = {
      healthCheckId = "$.detail.healthCheckId"
      status        = "$.detail.status"
      time          = "$.time"
    }
    input_template = "\"Route53 health check state changed at <time>. HealthCheckId: <healthCheckId>. New status: <status>. Domain: ${var.domain_name}.\""
  }
}

# SNS topic policy allowing EventBridge to publish
resource "aws_sns_topic_policy" "failover" {
  count    = var.enable_alarms ? 1 : 0
  provider = aws.us_east_1

  arn = aws_sns_topic.failover[0].arn

  policy = data.aws_iam_policy_document.sns_failover_policy[0].json
}

data "aws_iam_policy_document" "sns_failover_policy" {
  count = var.enable_alarms ? 1 : 0

  statement {
    sid    = "AllowCloudWatchAlarms"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.failover[0].arn]
  }

  statement {
    sid    = "AllowEventBridge"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.failover[0].arn]
  }

  statement {
    sid    = "AllowOwnerFullAccess"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [data.aws_caller_identity.current.arn]
    }

    actions   = ["SNS:*"]
    resources = [aws_sns_topic.failover[0].arn]
  }
}

# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
