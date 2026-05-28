# ---------------------------------------------------------------------------
# Core resource identifiers
# ---------------------------------------------------------------------------

output "task_definition_arn" {
  description = "ARN of the ECS task definition (includes revision number)."
  value       = aws_ecs_task_definition.this.arn
}

output "task_definition_family" {
  description = "Task definition family name. Use this to reference the task definition without pinning to a specific revision."
  value       = aws_ecs_task_definition.this.family
}

# ---------------------------------------------------------------------------
# IAM roles
# ---------------------------------------------------------------------------

output "task_role_arn" {
  description = "ARN of the IAM task role (the role your container code runs as)."
  value       = aws_iam_role.task.arn
}

output "task_role_name" {
  description = "Name of the IAM task role."
  value       = aws_iam_role.task.name
}

output "execution_role_arn" {
  description = "ARN of the IAM execution role (used by the ECS agent)."
  value       = aws_iam_role.execution.arn
}

output "execution_role_name" {
  description = "Name of the IAM execution role."
  value       = aws_iam_role.execution.name
}

output "events_role_arn" {
  description = "ARN of the IAM role EventBridge uses to call ecs:RunTask."
  value       = aws_iam_role.events.arn
}

# ---------------------------------------------------------------------------
# Security group
# ---------------------------------------------------------------------------

output "security_group_id" {
  description = "ID of the security group attached to Fargate tasks."
  value       = aws_security_group.task.id
}

# ---------------------------------------------------------------------------
# EventBridge
# ---------------------------------------------------------------------------

output "event_rule_arn" {
  description = "ARN of the EventBridge schedule rule."
  value       = aws_cloudwatch_event_rule.schedule.arn
}

output "event_rule_name" {
  description = "Name of the EventBridge schedule rule."
  value       = aws_cloudwatch_event_rule.schedule.name
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

output "log_group_name" {
  description = "CloudWatch log group name for task logs."
  value       = aws_cloudwatch_log_group.this.name
}

output "log_group_arn" {
  description = "CloudWatch log group ARN."
  value       = aws_cloudwatch_log_group.this.arn
}

# ---------------------------------------------------------------------------
# Optional: dead letter queue
# ---------------------------------------------------------------------------

output "dlq_url" {
  description = "SQS DLQ URL. Empty string if enable_dlq is false."
  value       = var.enable_dlq ? aws_sqs_queue.dlq[0].url : ""
}

output "dlq_arn" {
  description = "SQS DLQ ARN. Empty string if enable_dlq is false."
  value       = var.enable_dlq ? aws_sqs_queue.dlq[0].arn : ""
}

# ---------------------------------------------------------------------------
# Optional: failure notifications
# ---------------------------------------------------------------------------

output "failure_sns_topic_arn" {
  description = "ARN of the SNS topic for failure notifications. Empty string if enable_failure_notifications is false."
  value       = var.enable_failure_notifications ? aws_sns_topic.failure[0].arn : ""
}

# ---------------------------------------------------------------------------
# Alarm
# ---------------------------------------------------------------------------

output "failed_invocations_alarm_arn" {
  description = "ARN of the CloudWatch alarm on EventBridge FailedInvocations."
  value       = aws_cloudwatch_metric_alarm.failed_invocations.arn
}
