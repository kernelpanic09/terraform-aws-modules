output "webhook_url" {
  description = "HTTPS URL to configure as the GitHub webhook endpoint. Set the Content type to 'application/json' and scope to 'workflow_job' events."
  value       = "${aws_apigatewayv2_api.webhook.api_endpoint}/webhook"
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster running the runner fleet."
  value       = aws_ecs_cluster.runners.name
}

output "ecs_cluster_arn" {
  description = "ARN of the ECS cluster running the runner fleet."
  value       = aws_ecs_cluster.runners.arn
}

output "ecs_service_name" {
  description = "Name of the ECS service managing runner tasks."
  value       = aws_ecs_service.runners.name
}

output "ecs_service_id" {
  description = "Full ARN of the ECS service managing runner tasks."
  value       = aws_ecs_service.runners.id
}

output "lambda_function_name" {
  description = "Name of the Lambda function that processes GitHub webhooks."
  value       = aws_lambda_function.webhook.function_name
}

output "lambda_function_arn" {
  description = "ARN of the webhook Lambda function."
  value       = aws_lambda_function.webhook.arn
}

output "api_gateway_id" {
  description = "ID of the API Gateway HTTP API."
  value       = aws_apigatewayv2_api.webhook.id
}

output "runner_security_group_id" {
  description = "ID of the security group applied to runner ECS tasks."
  value       = aws_security_group.runners.id
}

output "runner_log_group_name" {
  description = "CloudWatch Log Group name for runner container output."
  value       = aws_cloudwatch_log_group.runners.name
}

output "lambda_log_group_name" {
  description = "CloudWatch Log Group name for the webhook Lambda function."
  value       = aws_cloudwatch_log_group.lambda.name
}

output "dlq_url" {
  description = "URL of the SQS dead-letter queue for failed webhook invocations. Empty string when enable_dlq is false."
  value       = var.enable_dlq ? aws_sqs_queue.dlq[0].url : ""
}

output "dlq_arn" {
  description = "ARN of the SQS dead-letter queue. Empty string when enable_dlq is false."
  value       = var.enable_dlq ? aws_sqs_queue.dlq[0].arn : ""
}

output "ecs_task_role_arn" {
  description = "ARN of the ECS task role. Attach additional policies to this role to grant runner containers access to AWS resources."
  value       = aws_iam_role.ecs_task.arn
}

output "ecs_task_execution_role_arn" {
  description = "ARN of the ECS task execution role used by the ECS agent to pull images and write logs."
  value       = aws_iam_role.ecs_task_execution.arn
}
