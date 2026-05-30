# ──────────────────────────────────────────────────────────────────────────
# Bedrock Knowledge Base with OpenSearch Serverless vector store
# ──────────────────────────────────────────────────────────────────────────
# This module provisions a complete RAG (Retrieval-Augmented Generation)
# backend: a vector store, the knowledge base itself, an S3 data source, and
# an optional Lambda that triggers re-indexing when documents change.
#
# Escaping note: the inline Python (Lambda) uses single braces ({...}) which
# Terraform leaves untouched. Where a literal "${" must appear inside a heredoc
# or string template it is written as "$${" so Terraform does not interpret it
# as its own interpolation; real Terraform references use the normal ${...} form.
#
# ──────────────────────────────────────────────────────────────────────────

# ── locals ───────────────────────────────────────────────────────────────────
locals {
  collection_name = var.collection_name != null ? var.collection_name : "${var.project_name}-kb"
}

# ── OpenSearch Serverless collection (vector store) ──────────────────────────
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# Encryption policy must exist before the collection
resource "aws_opensearchserverless_security_policy" "encryption" {
  name = "${var.project_name}-enc"
  type = "encryption"

  policy = jsonencode({
    Rules = [
      {
        ResourceType = "collection"
        Resource     = ["collection/${local.collection_name}"]
      }
    ]
    AWSOwnedKey = true
  })
}

# Network policy — allow public access to the collection endpoint and dashboards
resource "aws_opensearchserverless_security_policy" "network" {
  name = "${var.project_name}-net"
  type = "network"

  policy = jsonencode([
    {
      Rules = [
        {
          ResourceType = "collection"
          Resource     = ["collection/${local.collection_name}"]
        },
        {
          ResourceType = "dashboard"
          Resource     = ["collection/${local.collection_name}"]
        }
      ]
      AllowFromPublic = true
    }
  ])
}

# Data access policy — grant the KB role full access to the index
resource "aws_opensearchserverless_access_policy" "data" {
  name = "${var.project_name}-data"
  type = "data"

  policy = jsonencode([
    {
      Rules = [
        {
          ResourceType = "index"
          Resource     = ["index/${local.collection_name}/*"]
          Permission   = ["aoss:*"]
        },
        {
          ResourceType = "collection"
          Resource     = ["collection/${local.collection_name}"]
          Permission   = ["aoss:*"]
        }
      ]
      Principal = [aws_iam_role.kb.arn]
    }
  ])
}

# The collection itself
resource "aws_opensearchserverless_collection" "this" {
  name = local.collection_name
  type = "VECTORSEARCH"

  depends_on = [
    aws_opensearchserverless_security_policy.encryption,
    aws_opensearchserverless_security_policy.network
  ]

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

# ── IAM role for the knowledge base ──────────────────────────────────────────
resource "aws_iam_role" "kb" {
  name = "${var.project_name}-kb-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "bedrock.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "kb" {
  name = "${var.project_name}-kb-policy"
  role = aws_iam_role.kb.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["bedrock:InvokeModel"]
        Effect   = "Allow"
        Resource = var.embedding_model_arn
      },
      {
        Action   = ["aoss:APIAccessAll"]
        Effect   = "Allow"
        Resource = aws_opensearchserverless_collection.this.arn
      },
      {
        Action = ["s3:GetObject", "s3:ListBucket"]
        Effect = "Allow"
        Resource = [
          var.data_source_bucket_arn,
          "${var.data_source_bucket_arn}/*"
        ]
      }
    ]
  })
}

# ── Knowledge base resource ──────────────────────────────────────────────────
resource "aws_bedrockagent_knowledge_base" "this" {
  name     = "${var.project_name}-kb"
  role_arn = aws_iam_role.kb.arn

  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration {
      embedding_model_arn = var.embedding_model_arn
    }
  }

  storage_configuration {
    type = "OPENSEARCH_SERVERLESS"
    opensearch_serverless_configuration {
      collection_arn    = aws_opensearchserverless_collection.this.arn
      vector_index_name = "${var.project_name}-index"
      field_mapping {
        metadata_field = var.metadata_field
        text_field     = "AMAZON_BEDROCK_TEXT_CHUNK"
        vector_field   = "AMAZON_BEDROCK_VECTOR"
      }
    }
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

# ── Data source (S3) ─────────────────────────────────────────────────────────
resource "aws_bedrockagent_data_source" "this" {
  knowledge_base_id = aws_bedrockagent_knowledge_base.this.id
  name              = "${var.project_name}-s3-source"

  data_source_configuration {
    type = "S3"
    s3_configuration {
      bucket_arn = var.data_source_bucket_arn
    }
  }

  vector_ingestion_configuration {
    chunking_configuration {
      chunking_strategy = "FIXED_SIZE"
      fixed_size_chunking_configuration {
        max_tokens         = var.chunk_size
        overlap_percentage = var.chunk_overlap_percentage
      }
    }
  }
}

# ── CloudWatch log group for the sync Lambda ─────────────────────────────────
resource "aws_cloudwatch_log_group" "sync_lambda" {
  count = var.enable_auto_sync ? 1 : 0

  name              = "/aws/lambda/${var.project_name}-kb-sync"
  retention_in_days = 14
}

# ── IAM role for the sync Lambda ─────────────────────────────────────────────
resource "aws_iam_role" "sync_lambda" {
  count = var.enable_auto_sync ? 1 : 0

  name = "${var.project_name}-kb-sync-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# ── IAM role policy for the sync Lambda ──────────────────────────────────────
resource "aws_iam_role_policy" "sync_lambda" {
  count = var.enable_auto_sync ? 1 : 0

  name = "${var.project_name}-kb-sync-policy"
  role = aws_iam_role.sync_lambda[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "BedrockIngestion"
        Effect   = "Allow"
        Action   = ["bedrock:StartIngestionJob"]
        Resource = aws_bedrockagent_knowledge_base.this.arn
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.sync_lambda[0].arn}:*"
      }
    ]
  })
}

# ── Lambda function for triggering knowledge base sync ───────────────────────
# Automatically starts an ingestion job when source documents change.
resource "aws_lambda_function" "sync" {
  count = var.enable_auto_sync ? 1 : 0

  filename         = data.archive_file.sync_lambda[0].output_path
  function_name    = "${var.project_name}-kb-sync"
  role             = aws_iam_role.sync_lambda[0].arn
  handler          = "index.handler"
  source_code_hash = data.archive_file.sync_lambda[0].output_base64sha256
  runtime          = "python3.12"
  timeout          = 300

  environment {
    variables = {
      KNOWLEDGE_BASE_ID = aws_bedrockagent_knowledge_base.this.id
      DATA_SOURCE_ID    = aws_bedrockagent_data_source.this.id
    }
  }

  tags = {
    Name        = "${var.project_name}-kb-sync"
    Environment = var.environment
    Project     = var.project_name
  }
}

# ── Lambda source code (inline via archive_file) ─────────────────────────────
data "archive_file" "sync_lambda" {
  count = var.enable_auto_sync ? 1 : 0

  type        = "zip"
  output_path = "${path.module}/sync_lambda.zip"

  source {
    content  = <<-PYTHON
      import json
      import boto3
      import os
      import urllib3
      import time
      from datetime import datetime

      def handler(event, context):
        # Trigger Bedrock Knowledge Base ingestion job
        client = boto3.client('bedrock-agent')

        knowledge_base_id = os.environ['KNOWLEDGE_BASE_ID']
        data_source_id = os.environ['DATA_SOURCE_ID']

        response = client.start_ingestion_job(
            knowledgeBaseId=knowledge_base_id,
            dataSourceId=data_source_id
        )

        job = response['ingestionJob']

        return {
            'statusCode': 200,
            'body': json.dumps({
                'jobId': job['ingestionJobId'],
                'status': job['status'],
                'message': f'Ingestion job started: {job["ingestionJobId"]}'
            }, default=str)
        }
    PYTHON
    filename = "index.py"
  }
}
