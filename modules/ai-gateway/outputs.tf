output "api_endpoint" {
  description = "Base URL of the AI Gateway API (use this as base_url in OpenAI clients)."
  value       = aws_apigatewayv2_api.main.api_endpoint
}

output "api_id" {
  description = "ID of the API Gateway HTTP API."
  value       = aws_apigatewayv2_api.main.id
}

output "api_execution_arn" {
  description = "Execution ARN of the API Gateway HTTP API, needed for Lambda permission policies."
  value       = aws_apigatewayv2_api.main.execution_arn
}

output "proxy_lambda_arn" {
  description = "ARN of the proxy Lambda function."
  value       = aws_lambda_function.proxy.arn
}

output "proxy_lambda_name" {
  description = "Name of the proxy Lambda function."
  value       = aws_lambda_function.proxy.function_name
}

output "authorizer_lambda_arn" {
  description = "ARN of the authorizer Lambda function."
  value       = aws_lambda_function.authorizer.arn
}

output "api_keys_table_name" {
  description = "Name of the DynamoDB table holding API key records."
  value       = aws_dynamodb_table.api_keys.name
}

output "api_keys_table_arn" {
  description = "ARN of the DynamoDB api_keys table."
  value       = aws_dynamodb_table.api_keys.arn
}

output "cost_log_table_name" {
  description = "Name of the DynamoDB cost log table."
  value       = aws_dynamodb_table.cost_log.name
}

output "prompt_cache_table_name" {
  description = "Name of the DynamoDB prompt cache table."
  value       = aws_dynamodb_table.prompt_cache.name
}

output "rate_counter_table_name" {
  description = "Name of the DynamoDB rate counter table."
  value       = aws_dynamodb_table.rate_counter.name
}

output "kms_key_arn" {
  description = "ARN of the KMS key used for DynamoDB encryption."
  value       = aws_kms_key.main.arn
}

output "kms_key_id" {
  description = "ID of the KMS key used for DynamoDB encryption."
  value       = aws_kms_key.main.key_id
}

output "sns_alarm_topic_arn" {
  description = "ARN of the SNS topic that receives CloudWatch alarm notifications."
  value       = aws_sns_topic.alarms.arn
}

output "dashboard_url" {
  description = "URL of the CloudWatch dashboard for this gateway."
  value       = "https://${data.aws_region.current.name}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.name}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}

output "waf_web_acl_arn" {
  description = "ARN of the WAF WebACL (empty string if enable_waf is false)."
  value       = var.enable_waf ? aws_wafv2_web_acl.main[0].arn : ""
}

output "chat_completions_endpoint" {
  description = "Full URL for the /v1/chat/completions endpoint."
  value       = "${aws_apigatewayv2_api.main.api_endpoint}/v1/chat/completions"
}

output "embeddings_endpoint" {
  description = "Full URL for the /v1/embeddings endpoint."
  value       = "${aws_apigatewayv2_api.main.api_endpoint}/v1/embeddings"
}
