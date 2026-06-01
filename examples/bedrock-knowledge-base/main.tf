terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.50.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      ManagedBy   = "terraform"
      Module      = "bedrock-knowledge-base"
      Environment = var.environment
    }
  }
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment label (e.g. dev, staging, production)."
  type        = string
  default     = "dev"
}

variable "developer_role_name" {
  description = "Name of the IAM role that should receive read/query access to the OpenSearch collection. Used to construct the role ARN."
  type        = string
  default     = "developer-role"
}

# ---------------------------------------------------------------------------
# Look up the current account ID to build the developer role ARN
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  developer_role_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.developer_role_name}"
}

# ---------------------------------------------------------------------------
# Bedrock Knowledge Base module
# ---------------------------------------------------------------------------

module "docs_kb" {
  source = "../../modules/bedrock-knowledge-base"

  # Unique name for this knowledge base and all derived resources.
  # Must be 3-32 characters, lowercase letters, numbers, and hyphens only.
  name = "docs-${var.environment}"

  # Embedding model: use the default Amazon Titan Embed Text v2.
  # 1024-dimensional vectors, good balance of quality and cost.
  embedding_model = "amazon.titan-embed-text-v2:0"

  # FIXED_SIZE chunking: split documents into 500-token chunks with
  # 20% overlap (100 tokens) so that context is not lost at boundaries.
  chunking_strategy = {
    type               = "FIXED_SIZE"
    max_tokens         = 500
    overlap_percentage = 20
  }

  # Only ingest files under the "documents/" prefix.
  # Upload files here: aws s3 cp myfile.pdf s3://<bucket>/documents/
  s3_inclusion_prefixes = ["documents/"]

  # Enable the auto-ingestion Lambda so the knowledge base refreshes
  # automatically whenever new files land in the S3 bucket.
  enable_auto_ingestion = true

  # Grant the developer IAM role read-only query access to the
  # OpenSearch Serverless collection (for direct API debugging).
  additional_query_principals = [
    local.developer_role_arn,
  ]

  # Use AWS-managed encryption (no CMK required for this example).
  # For production, provide kms_key_arn = "arn:aws:kms:..."
  kms_key_arn = null

  # Lambda reserved concurrency: allow up to 5 concurrent ingestion triggers.
  lambda_reserved_concurrency = 5

  # Retain logs for 30 days.
  log_retention_days = 30

  tags = {
    Environment = var.environment
    CostCenter  = "platform"
    Owner       = "platform-team"
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "knowledge_base_id" {
  description = "Pass this ID to Bedrock Retrieve and RetrieveAndGenerate API calls."
  value       = module.docs_kb.knowledge_base_id
}

output "knowledge_base_arn" {
  description = "ARN of the knowledge base (useful for IAM policies in consuming services)."
  value       = module.docs_kb.knowledge_base_arn
}

output "data_source_id" {
  description = "ID of the S3 data source. Required for StartIngestionJob API calls."
  value       = module.docs_kb.data_source_id
}

output "s3_bucket_name" {
  description = "Upload documents here to populate the knowledge base."
  value       = module.docs_kb.s3_bucket_name
}

output "opensearch_collection_endpoint" {
  description = "Direct HTTPS endpoint for the OpenSearch Serverless collection."
  value       = module.docs_kb.opensearch_collection_endpoint
}

output "opensearch_dashboard_endpoint" {
  description = "OpenSearch Dashboards URL for exploring the vector index."
  value       = module.docs_kb.opensearch_dashboard_endpoint
}

output "lambda_function_name" {
  description = "Name of the auto-ingestion Lambda (for monitoring and manual invocation)."
  value       = module.docs_kb.lambda_function_name
}

output "lambda_dlq_url" {
  description = "SQS dead-letter queue URL. Check here for failed ingestion trigger events."
  value       = module.docs_kb.lambda_dlq_url
}

output "retrieve_and_generate_config" {
  description = "Full configuration block needed to call the Bedrock RetrieveAndGenerate API."
  value       = module.docs_kb.retrieve_and_generate_config
}

# ---------------------------------------------------------------------------
# Quick-start commands (printed as a local_file or just read the outputs)
# ---------------------------------------------------------------------------
#
# After `terraform apply`:
#
# 1. Upload a document:
#    aws s3 cp my-doc.pdf s3://$(terraform output -raw s3_bucket_name)/documents/
#
# 2. Trigger ingestion manually (or wait for auto-ingestion Lambda):
#    aws bedrock-agent start-ingestion-job \
#      --knowledge-base-id $(terraform output -raw knowledge_base_id) \
#      --data-source-id $(terraform output -raw data_source_id)
#
# 3. Query the knowledge base:
#    aws bedrock-agent-runtime retrieve \
#      --knowledge-base-id $(terraform output -raw knowledge_base_id) \
#      --retrieval-query '{"text": "What is the return policy?"}' \
#      --retrieval-configuration '{"vectorSearchConfiguration":{"numberOfResults":5}}'
#
# 4. Check Lambda DLQ for any failed events:
#    aws sqs get-queue-attributes \
#      --queue-url $(terraform output -raw lambda_dlq_url) \
#      --attribute-names ApproximateNumberOfMessages
