# ---------------------------------------------------------------------------
# Health check outputs
# ---------------------------------------------------------------------------

output "primary_health_check_id" {
  description = "The ID of the Route53 health check for the primary endpoint."
  value       = aws_route53_health_check.primary.id
}

output "primary_health_check_arn" {
  description = "The ARN of the Route53 health check for the primary endpoint."
  value       = aws_route53_health_check.primary.arn
}

output "secondary_health_check_id" {
  description = "The ID of the Route53 health check for the secondary endpoint."
  value       = aws_route53_health_check.secondary.id
}

output "secondary_health_check_arn" {
  description = "The ARN of the Route53 health check for the secondary endpoint."
  value       = aws_route53_health_check.secondary.arn
}

output "calculated_health_check_id" {
  description = "The ID of the calculated (aggregated) Route53 health check. Null when enable_calculated_health_check = false."
  value       = var.enable_calculated_health_check ? aws_route53_health_check.calculated[0].id : null
}

# ---------------------------------------------------------------------------
# DNS record outputs
# ---------------------------------------------------------------------------

output "primary_record_fqdn" {
  description = "The fully qualified domain name of the primary A record."
  value       = aws_route53_record.primary_a.fqdn
}

output "secondary_record_fqdn" {
  description = "The fully qualified domain name of the secondary A record."
  value       = aws_route53_record.secondary_a.fqdn
}

output "primary_record_name" {
  description = "The DNS name of the primary A record as returned by Route53."
  value       = aws_route53_record.primary_a.name
}

output "primary_aaaa_record_fqdn" {
  description = "The fully qualified domain name of the primary AAAA record. Null when enable_ipv6 = false."
  value       = var.enable_ipv6 ? aws_route53_record.primary_aaaa[0].fqdn : null
}

output "secondary_aaaa_record_fqdn" {
  description = "The fully qualified domain name of the secondary AAAA record. Null when enable_ipv6 = false."
  value       = var.enable_ipv6 ? aws_route53_record.secondary_aaaa[0].fqdn : null
}

# ---------------------------------------------------------------------------
# SNS and alarm outputs
# ---------------------------------------------------------------------------

output "sns_topic_arn" {
  description = "ARN of the SNS topic used for health check failure notifications. Null when enable_alarms = false."
  value       = var.enable_alarms ? aws_sns_topic.failover[0].arn : null
}

output "sns_topic_name" {
  description = "Name of the SNS topic. Null when enable_alarms = false."
  value       = var.enable_alarms ? aws_sns_topic.failover[0].name : null
}

output "primary_alarm_arn" {
  description = "ARN of the CloudWatch alarm monitoring the primary health check. Null when enable_alarms = false."
  value       = var.enable_alarms ? aws_cloudwatch_metric_alarm.primary_health_check[0].arn : null
}

output "secondary_alarm_arn" {
  description = "ARN of the CloudWatch alarm monitoring the secondary health check. Null when enable_alarms = false."
  value       = var.enable_alarms ? aws_cloudwatch_metric_alarm.secondary_health_check[0].arn : null
}

output "composite_alarm_arn" {
  description = "ARN of the composite alarm that fires when both endpoints are down. Null when enable_composite_alarm = false."
  value       = var.enable_alarms && var.enable_composite_alarm ? aws_cloudwatch_composite_alarm.both_endpoints_down[0].arn : null
}

output "primary_latency_alarm_arn" {
  description = "ARN of the CloudWatch alarm monitoring primary endpoint latency. Null when measure_latency = false."
  value       = var.enable_alarms && var.measure_latency ? aws_cloudwatch_metric_alarm.primary_latency[0].arn : null
}

output "eventbridge_rule_arn" {
  description = "ARN of the EventBridge rule that forwards Route53 state change events to SNS. Null when enable_eventbridge_rule = false."
  value       = var.enable_alarms && var.enable_eventbridge_rule ? aws_cloudwatch_event_rule.health_check_state_change[0].arn : null
}
