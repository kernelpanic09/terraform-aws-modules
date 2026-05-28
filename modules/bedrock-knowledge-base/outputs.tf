# ============================================================
# Knowledge Base outputs
# ============================================================

output "knowledge_base_id" {
  description = "ID of the Bedrock Knowledge Base."
  value       = aws_bedrockagent_knowledge_base.this.id
}

output "knowledge_base_arn" {
  description = "ARN of the Bedrock Knowledge Base."
  value       = aws_bedrockagent_knowledge_base.this.arn
}

output "knowledge_base_name" {
  description = "Name of the Bedrock Knowledge Base."
  value       = aws_bedrockagent_knowledge_base.this.name
}

output "data_source_id" {
  description = "ID of the Bedrock Data Source connected to the S3 bucket."
  value       = aws_bedrockagent_data_source.s3.data_source_id
}

# ============================================================
# OpenSearch Serverless outputs
# ============================================================

output "opensearch_collection_id" {
  description = "ID of the OpenSearch Serverless collection."
  value       = aws_opensearchserverless_collection.this.id
}

output "opensearch_collection_arn" {
  description = "ARN of the OpenSearch Serverless collection."
  value       = aws_opensearchserverless_collection.this.arn
}

output "opensearch_collection_endpoint" {
  description = "HTTPS endpoint of the OpenSearch Serverless collection. Use this to query the collection directly or to create additional indexes."
  value       = aws_opensearchserverless_collection.this.collection_endpoint
}

output "opensearch_dashboard_endpoint" {
  description = "URL of the OpenSearch Dashboards UI for the collection."
  value       = aws_opensearchserverless_collection.this.dashboard_endpoint
}

output "vector_index_name" {
  description = "Name of the vector index created inside the OpenSearch Serverless collection."
  value       = local.vector_index_name
}

# ============================================================
# S3 outputs
# ============================================================

output "s3_bucket_name" {
  description = "Name of the S3 bucket used as the document source."
  value       = local.s3_bucket_name
}

output "s3_bucket_arn" {
  description = "ARN of the S3 bucket used as the document source."
  value       = "arn:${local.partition}:s3:::${local.s3_bucket_name}"
}

output "s3_bucket_created" {
  description = "Whether this module created the S3 bucket (true) or used an existing one (false)."
  value       = local.create_s3_bucket
}

# ============================================================
# IAM outputs
# ============================================================

output "bedrock_role_arn" {
  description = "ARN of the IAM service role used by the Bedrock Knowledge Base."
  value       = aws_iam_role.bedrock.arn
}

output "bedrock_role_name" {
  description = "Name of the IAM service role used by the Bedrock Knowledge Base."
  value       = aws_iam_role.bedrock.name
}

# ============================================================
# Auto-ingestion Lambda outputs (null when disabled)
# ============================================================

output "lambda_function_arn" {
  description = "ARN of the auto-ingestion Lambda function. Null when enable_auto_ingestion is false."
  value       = var.enable_auto_ingestion ? aws_lambda_function.auto_ingestion[0].arn : null
}

output "lambda_function_name" {
  description = "Name of the auto-ingestion Lambda function. Null when enable_auto_ingestion is false."
  value       = var.enable_auto_ingestion ? aws_lambda_function.auto_ingestion[0].function_name : null
}

output "lambda_dlq_arn" {
  description = "ARN of the SQS dead-letter queue for the auto-ingestion Lambda. Null when enable_auto_ingestion is false."
  value       = var.enable_auto_ingestion ? aws_sqs_queue.lambda_dlq[0].arn : null
}

output "lambda_dlq_url" {
  description = "URL of the SQS dead-letter queue for the auto-ingestion Lambda. Null when enable_auto_ingestion is false."
  value       = var.enable_auto_ingestion ? aws_sqs_queue.lambda_dlq[0].url : null
}

# ============================================================
# CloudWatch outputs
# ============================================================

output "bedrock_log_group_name" {
  description = "Name of the CloudWatch log group for Bedrock Knowledge Base activity."
  value       = aws_cloudwatch_log_group.bedrock.name
}

output "lambda_log_group_name" {
  description = "Name of the CloudWatch log group for the auto-ingestion Lambda. Null when enable_auto_ingestion is false."
  value       = var.enable_auto_ingestion ? aws_cloudwatch_log_group.lambda[0].name : null
}

# ============================================================
# Convenience outputs for Bedrock API callers
# ============================================================

output "retrieve_and_generate_config" {
  description = "Convenience map containing the IDs needed to call Bedrock RetrieveAndGenerate or Retrieve APIs."
  value = {
    knowledge_base_id  = aws_bedrockagent_knowledge_base.this.id
    data_source_id     = aws_bedrockagent_data_source.s3.data_source_id
    embedding_model    = var.embedding_model
    vector_index_name  = local.vector_index_name
  }
}
