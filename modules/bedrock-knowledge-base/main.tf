# ============================================================
# Data sources
# ============================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

# ============================================================
# Locals
# ============================================================

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
  partition  = data.aws_partition.current.partition

  # Deterministic index name derived from the module name
  vector_index_name = "${var.name}-index"

  # S3 bucket: use provided name or generate one
  create_s3_bucket = var.s3_bucket_name == null || var.s3_bucket_name == ""
  s3_bucket_name   = local.create_s3_bucket ? "${var.name}-kb-docs-${local.account_id}" : var.s3_bucket_name

  # Embedding model ARN
  embedding_model_arn = "arn:${local.partition}:bedrock:${local.region}::foundation-model/${var.embedding_model}"

  # Merge user tags with mandatory module tags
  common_tags = merge(var.tags, {
    "bedrock-kb:module" = "bedrock-knowledge-base"
    "bedrock-kb:name"   = var.name
  })
}

# ============================================================
# S3 Bucket (source documents)
# ============================================================

resource "aws_s3_bucket" "docs" {
  count = local.create_s3_bucket ? 1 : 0

  bucket        = local.s3_bucket_name
  force_destroy = false

  tags = local.common_tags
}

resource "aws_s3_bucket_versioning" "docs" {
  count = local.create_s3_bucket ? 1 : 0

  bucket = aws_s3_bucket.docs[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "docs" {
  count = local.create_s3_bucket ? 1 : 0

  bucket = aws_s3_bucket.docs[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn != null ? "aws:kms" : "AES256"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = var.kms_key_arn != null
  }
}

resource "aws_s3_bucket_public_access_block" "docs" {
  count = local.create_s3_bucket ? 1 : 0

  bucket = aws_s3_bucket.docs[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "docs" {
  count = local.create_s3_bucket ? 1 : 0

  bucket = aws_s3_bucket.docs[0].id

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

# Allow Bedrock to read from the S3 bucket
resource "aws_s3_bucket_policy" "docs" {
  count = local.create_s3_bucket ? 1 : 0

  bucket = aws_s3_bucket.docs[0].id
  policy = data.aws_iam_policy_document.s3_bucket_policy.json

  depends_on = [aws_s3_bucket_public_access_block.docs]
}

data "aws_iam_policy_document" "s3_bucket_policy" {
  statement {
    sid    = "AllowBedrockServicePrincipal"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }

    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]

    resources = [
      "arn:${local.partition}:s3:::${local.s3_bucket_name}",
      "arn:${local.partition}:s3:::${local.s3_bucket_name}/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:bedrock:${local.region}:${local.account_id}:knowledge-base/*"]
    }
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      "arn:${local.partition}:s3:::${local.s3_bucket_name}",
      "arn:${local.partition}:s3:::${local.s3_bucket_name}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

# ============================================================
# IAM Role for Bedrock Knowledge Base
# ============================================================

data "aws_iam_policy_document" "bedrock_assume_role" {
  statement {
    sid    = "AllowBedrockAssumeRole"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:bedrock:${local.region}:${local.account_id}:knowledge-base/*"]
    }
  }
}

resource "aws_iam_role" "bedrock" {
  name               = "${var.name}-bedrock-kb-role"
  assume_role_policy = data.aws_iam_policy_document.bedrock_assume_role.json
  description        = "Service role for Bedrock Knowledge Base: ${var.name}"

  tags = local.common_tags
}

data "aws_iam_policy_document" "bedrock_permissions" {
  # Allow invoking the embedding model
  statement {
    sid    = "AllowInvokeEmbeddingModel"
    effect = "Allow"

    actions = ["bedrock:InvokeModel"]

    resources = [local.embedding_model_arn]
  }

  # Allow reading from the source S3 bucket
  statement {
    sid    = "AllowS3Read"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]

    resources = [
      "arn:${local.partition}:s3:::${local.s3_bucket_name}",
      "arn:${local.partition}:s3:::${local.s3_bucket_name}/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceAccount"
      values   = [local.account_id]
    }
  }

  # Allow querying and writing to OpenSearch Serverless
  statement {
    sid    = "AllowOpenSearchServerlessAccess"
    effect = "Allow"

    actions = ["aoss:APIAccessAll"]

    resources = [aws_opensearchserverless_collection.this.arn]
  }

  # Allow KMS decrypt if a CMK is provided
  dynamic "statement" {
    for_each = var.kms_key_arn != null ? [1] : []

    content {
      sid    = "AllowKMSDecrypt"
      effect = "Allow"

      actions = [
        "kms:Decrypt",
        "kms:GenerateDataKey",
        "kms:DescribeKey",
      ]

      resources = [var.kms_key_arn]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["s3.${local.region}.amazonaws.com"]
      }
    }
  }
}

resource "aws_iam_role_policy" "bedrock_permissions" {
  name   = "${var.name}-bedrock-kb-policy"
  role   = aws_iam_role.bedrock.id
  policy = data.aws_iam_policy_document.bedrock_permissions.json
}

# ============================================================
# OpenSearch Serverless - Encryption Policy
# ============================================================

resource "aws_opensearchserverless_security_policy" "encryption" {
  name        = "${var.name}-enc"
  type        = "encryption"
  description = "Encryption policy for ${var.name} vector collection"

  policy = jsonencode({
    Rules = [
      {
        Resource     = ["collection/${var.name}"]
        ResourceType = "collection"
      }
    ]
    AWSOwnedKey = var.kms_key_arn == null
    KmsARN      = var.kms_key_arn
  })
}

# ============================================================
# OpenSearch Serverless - Network Policy
# ============================================================

resource "aws_opensearchserverless_security_policy" "network" {
  name        = "${var.name}-net"
  type        = "network"
  description = "Network policy for ${var.name} vector collection - allows public endpoint access"

  # Allow public endpoint access so Bedrock service can reach the collection.
  # Access is still secured by the data access policy (IAM + AOSS rules).
  # For VPC-only deployments, replace SourceType "internet" with "vpc" and
  # provide a SourceVPCEs list.
  policy = jsonencode([
    {
      Rules = [
        {
          Resource     = ["collection/${var.name}"]
          ResourceType = "collection"
        },
        {
          Resource     = ["collection/${var.name}"]
          ResourceType = "dashboard"
        }
      ]
      AllowFromPublic = true
    }
  ])
}

# ============================================================
# OpenSearch Serverless - Collection
# ============================================================

resource "aws_opensearchserverless_collection" "this" {
  name        = var.name
  type        = "VECTORSEARCH"
  description = "Vector store for Bedrock Knowledge Base: ${var.name}"

  tags = local.common_tags

  depends_on = [
    aws_opensearchserverless_security_policy.encryption,
    aws_opensearchserverless_security_policy.network,
  ]
}

# ============================================================
# OpenSearch Serverless - Data Access Policy
# ============================================================

# Build the principal list dynamically so additional_query_principals
# is safely merged with the Bedrock service role.
locals {
  # Build data access policy statements; only include the additional-principals
  # statement when there are actually principals to grant access to.
  _aoss_bedrock_statement = {
    Description = "Full index access for Bedrock Knowledge Base role"
    Rules = [
      {
        Resource     = ["index/${var.name}/*"]
        ResourceType = "index"
        Permission = [
          "aoss:CreateIndex",
          "aoss:DeleteIndex",
          "aoss:UpdateIndex",
          "aoss:DescribeIndex",
          "aoss:ReadDocument",
          "aoss:WriteDocument",
        ]
      },
      {
        Resource     = ["collection/${var.name}"]
        ResourceType = "collection"
        Permission = [
          "aoss:CreateCollectionItems",
          "aoss:DeleteCollectionItems",
          "aoss:UpdateCollectionItems",
          "aoss:DescribeCollectionItems",
        ]
      }
    ]
    Principal = [aws_iam_role.bedrock.arn]
  }

  _aoss_query_statement = length(var.additional_query_principals) > 0 ? [{
    Description = "Read-only index access for additional query principals"
    Rules = [
      {
        Resource     = ["index/${var.name}/*"]
        ResourceType = "index"
        Permission = [
          "aoss:DescribeIndex",
          "aoss:ReadDocument",
        ]
      }
    ]
    Principal = var.additional_query_principals
  }] : []

  aoss_data_policy_statements = concat([local._aoss_bedrock_statement], local._aoss_query_statement)
}

resource "aws_opensearchserverless_access_policy" "data" {
  name        = "${var.name}-data"
  type        = "data"
  description = "Data access policy for ${var.name}: grants Bedrock role full index access"

  policy = jsonencode(local.aoss_data_policy_statements)
}

# ============================================================
# Vector Index creation via null_resource + local-exec
#
# OpenSearch Serverless does not expose a Terraform resource for
# index creation. The null_resource below uses the AWS CLI to
# send a signed HTTP PUT to the collection endpoint, creating
# the vector index with the exact field mapping that Bedrock
# expects. The AWS CLI must be installed and configured with
# credentials that have aoss:APIAccessAll on this collection.
#
# The index is created only once (triggers on collection ARN
# change). If you need to recreate it, taint this resource:
#   terraform taint null_resource.vector_index
# ============================================================

resource "null_resource" "vector_index" {
  triggers = {
    collection_arn      = aws_opensearchserverless_collection.this.arn
    collection_endpoint = aws_opensearchserverless_collection.this.collection_endpoint
    index_name          = local.vector_index_name
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-SCRIPT
      set -euo pipefail

      ENDPOINT="${aws_opensearchserverless_collection.this.collection_endpoint}"
      INDEX="${local.vector_index_name}"
      REGION="${local.region}"

      # Determine vector dimension based on embedding model
      case "${var.embedding_model}" in
        "amazon.titan-embed-text-v2:0")       DIMS=1024 ;;
        "amazon.titan-embed-text-v1:2:8k")    DIMS=1536 ;;
        "cohere.embed-english-v3")            DIMS=1024 ;;
        "cohere.embed-multilingual-v3")       DIMS=1024 ;;
        *)                                    DIMS=1024 ;;
      esac

      INDEX_BODY=$(cat <<EOF
      {
        "settings": {
          "index.knn": true,
          "number_of_shards": 2,
          "number_of_replicas": 0
        },
        "mappings": {
          "properties": {
            "bedrock-knowledge-base-default-vector": {
              "type": "knn_vector",
              "dimension": $DIMS,
              "method": {
                "name": "hnsw",
                "space_type": "cosinesimil",
                "engine": "faiss",
                "parameters": {
                  "ef_construction": 512,
                  "m": 16
                }
              }
            },
            "AMAZON_BEDROCK_TEXT_CHUNK": {
              "type": "text",
              "index": true
            },
            "AMAZON_BEDROCK_METADATA": {
              "type": "text",
              "index": false
            }
          }
        }
      }
      EOF
      )

      # Wait for the collection to become ACTIVE (up to 10 minutes)
      echo "Waiting for OpenSearch Serverless collection to be ACTIVE..."
      for i in $(seq 1 60); do
        STATUS=$(aws opensearchserverless get-collection \
          --id "${aws_opensearchserverless_collection.this.id}" \
          --region "$REGION" \
          --query 'collectionDetails.status' \
          --output text 2>/dev/null || echo "UNKNOWN")
        if [ "$STATUS" = "ACTIVE" ]; then
          echo "Collection is ACTIVE."
          break
        fi
        echo "  Status: $STATUS (attempt $i/60) - sleeping 10s..."
        sleep 10
        if [ "$i" -eq 60 ]; then
          echo "ERROR: Collection did not become ACTIVE within 10 minutes." >&2
          exit 1
        fi
      done

      # Resolve AWS credentials: prefer environment variables (IAM roles, ECS tasks,
      # CodeBuild, etc.) then fall back to configured profile credentials.
      ACCESS_KEY="$${AWS_ACCESS_KEY_ID:-$(aws configure get aws_access_key_id 2>/dev/null || echo "")}"
      SECRET_KEY="$${AWS_SECRET_ACCESS_KEY:-$(aws configure get aws_secret_access_key 2>/dev/null || echo "")}"
      SESSION_TOKEN="$${AWS_SESSION_TOKEN:-$(aws configure get aws_session_token 2>/dev/null || echo "")}"

      if [ -z "$ACCESS_KEY" ] || [ -z "$SECRET_KEY" ]; then
        echo "ERROR: Could not resolve AWS credentials. Set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY or configure the AWS CLI." >&2
        exit 1
      fi

      # Build optional session token header
      SESSION_HEADER=""
      if [ -n "$SESSION_TOKEN" ]; then
        SESSION_HEADER="-H x-amz-security-token:$SESSION_TOKEN"
      fi

      # Check whether the index already exists (idempotent guard)
      HTTP_STATUS=$(curl -s -o /dev/null -w "%%{http_code}" \
        --aws-sigv4 "aws:amz:$REGION:aoss" \
        --user "$ACCESS_KEY:$SECRET_KEY" \
        $SESSION_HEADER \
        "$ENDPOINT/$INDEX" 2>/dev/null || echo "000")

      if [ "$HTTP_STATUS" = "200" ]; then
        echo "Index '$INDEX' already exists. Skipping creation."
        exit 0
      fi

      echo "Creating vector index '$INDEX' on $ENDPOINT ..."

      # Check curl version for --aws-sigv4 support (requires >= 7.75.0)
      CURL_VERSION=$(curl --version 2>/dev/null | head -1 | awk '{print $2}')
      CURL_MAJOR=$(echo "$CURL_VERSION" | cut -d. -f1)
      CURL_MINOR=$(echo "$CURL_VERSION" | cut -d. -f2)
      SUPPORTS_SIGV4=false
      if [ "$CURL_MAJOR" -gt 7 ] 2>/dev/null; then
        SUPPORTS_SIGV4=true
      elif [ "$CURL_MAJOR" -eq 7 ] && [ "$CURL_MINOR" -ge 75 ] 2>/dev/null; then
        SUPPORTS_SIGV4=true
      fi

      if [ "$SUPPORTS_SIGV4" = "true" ]; then
        HTTP_CODE=$(curl -s -o /tmp/aoss_index_response.json -w "%%{http_code}" \
          --aws-sigv4 "aws:amz:$REGION:aoss" \
          --user "$ACCESS_KEY:$SECRET_KEY" \
          $SESSION_HEADER \
          -X PUT \
          -H "Content-Type: application/json" \
          -d "$INDEX_BODY" \
          "$ENDPOINT/$INDEX")
      else
        # Python fallback using boto3 for SigV4 signing (works on older curl)
        HTTP_CODE=$(python3 - <<PYEOF
import sys, json, os, urllib.request, urllib.error
try:
    import boto3
    from botocore.auth import SigV4Auth
    from botocore.awsrequest import AWSRequest
except ImportError:
    print("ERROR: boto3 is required as a fallback for index creation on this system.", file=sys.stderr)
    sys.exit(1)

region = os.environ.get("REGION", "$REGION")
endpoint = "$ENDPOINT"
index = "$INDEX"
url = f"{endpoint}/{index}"
index_body = json.dumps(json.loads('''$INDEX_BODY''')).encode("utf-8")

session = boto3.session.Session()
credentials = session.get_credentials().get_frozen_credentials()
request = AWSRequest(method="PUT", url=url, data=index_body, headers={"Content-Type": "application/json"})
SigV4Auth(credentials, "aoss", region).add_auth(request)
prepped = request.prepare()

req = urllib.request.Request(url, data=index_body, headers=dict(prepped.headers), method="PUT")
with open("/tmp/aoss_index_response.json", "w") as f:
    try:
        with urllib.request.urlopen(req) as resp:
            body = resp.read().decode()
            f.write(body)
            print(resp.status)
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        f.write(body)
        print(e.code)
PYEOF
        )
      fi

      RESPONSE_BODY=""
      [ -f /tmp/aoss_index_response.json ] && RESPONSE_BODY=$(cat /tmp/aoss_index_response.json)

      if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
        echo "Vector index '$INDEX' created successfully."
      elif echo "$RESPONSE_BODY" | grep -qi "resource_already_exists"; then
        echo "Index '$INDEX' already exists (idempotent - concurrent creation)."
      else
        echo "ERROR: Unexpected response (HTTP $HTTP_CODE): $RESPONSE_BODY" >&2
        exit 1
      fi
    SCRIPT
  }

  depends_on = [
    aws_opensearchserverless_collection.this,
    aws_opensearchserverless_access_policy.data,
    aws_iam_role_policy.bedrock_permissions,
  ]
}

# ============================================================
# CloudWatch Log Group (Bedrock)
# ============================================================

resource "aws_cloudwatch_log_group" "bedrock" {
  name              = "/aws/bedrock/knowledge-base/${var.name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = local.common_tags
}

# ============================================================
# Bedrock Knowledge Base
# ============================================================

resource "aws_bedrockagent_knowledge_base" "this" {
  name        = var.name
  description = "Knowledge base for ${var.name} - managed by Terraform"
  role_arn    = aws_iam_role.bedrock.arn

  knowledge_base_configuration {
    type = "VECTOR"

    vector_knowledge_base_configuration {
      embedding_model_arn = local.embedding_model_arn
    }
  }

  storage_configuration {
    type = "OPENSEARCH_SERVERLESS"

    opensearch_serverless_configuration {
      collection_arn    = aws_opensearchserverless_collection.this.arn
      vector_index_name = local.vector_index_name

      field_mapping {
        vector_field   = "bedrock-knowledge-base-default-vector"
        text_field     = "AMAZON_BEDROCK_TEXT_CHUNK"
        metadata_field = "AMAZON_BEDROCK_METADATA"
      }
    }
  }

  tags = local.common_tags

  depends_on = [
    null_resource.vector_index,
    aws_iam_role_policy.bedrock_permissions,
    aws_opensearchserverless_access_policy.data,
  ]
}

# ============================================================
# Bedrock Data Source
# ============================================================

resource "aws_bedrockagent_data_source" "s3" {
  name              = "${var.name}-s3-source"
  knowledge_base_id = aws_bedrockagent_knowledge_base.this.id
  description       = "S3 data source for ${var.name} knowledge base"

  data_source_configuration {
    type = "S3"

    s3_configuration {
      bucket_arn         = "arn:${local.partition}:s3:::${local.s3_bucket_name}"
      inclusion_prefixes = length(var.s3_inclusion_prefixes) > 0 ? var.s3_inclusion_prefixes : null
    }
  }

  vector_ingestion_configuration {
    chunking_configuration {
      chunking_strategy = var.chunking_strategy.type

      dynamic "fixed_size_chunking_configuration" {
        for_each = var.chunking_strategy.type == "FIXED_SIZE" ? [1] : []
        content {
          max_tokens         = var.chunking_strategy.max_tokens
          overlap_percentage = var.chunking_strategy.overlap_percentage
        }
      }
    }
  }
}

# ============================================================
# Auto-Ingestion Lambda (optional)
# ============================================================

# Dead-letter queue for failed Lambda invocations
resource "aws_sqs_queue" "lambda_dlq" {
  count = var.enable_auto_ingestion ? 1 : 0

  name                      = "${var.name}-ingestion-dlq"
  message_retention_seconds = 1209600 # 14 days
  kms_master_key_id         = var.kms_key_arn != null ? var.kms_key_arn : "alias/aws/sqs"

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "lambda" {
  count = var.enable_auto_ingestion ? 1 : 0

  name              = "/aws/lambda/${var.name}-auto-ingestion"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = local.common_tags
}

# IAM role for the Lambda function
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    sid    = "AllowLambdaAssumeRole"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "lambda" {
  count = var.enable_auto_ingestion ? 1 : 0

  name               = "${var.name}-auto-ingestion-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  description        = "Execution role for ${var.name} auto-ingestion Lambda"

  tags = local.common_tags
}

data "aws_iam_policy_document" "lambda_permissions" {
  # CloudWatch Logs
  statement {
    sid    = "AllowCloudWatchLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = [
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${var.name}-auto-ingestion",
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${var.name}-auto-ingestion:*",
    ]
  }

  # Bedrock: start ingestion job
  statement {
    sid    = "AllowStartIngestionJob"
    effect = "Allow"

    actions = ["bedrock:StartIngestionJob"]

    resources = [aws_bedrockagent_knowledge_base.this.arn]
  }

  # SQS: write to DLQ (the ARN is always computed; the policy document is only
  # attached to the Lambda role when enable_auto_ingestion is true)
  statement {
    sid    = "AllowSQSDeadLetter"
    effect = "Allow"

    actions = ["sqs:SendMessage"]

    # Use a conditional that avoids an index-out-of-bounds error when the queue
    # count is zero (data sources are always evaluated regardless of count).
    resources = [
      length(aws_sqs_queue.lambda_dlq) > 0
      ? aws_sqs_queue.lambda_dlq[0].arn
      : "arn:${local.partition}:sqs:${local.region}:${local.account_id}:${var.name}-ingestion-dlq"
    ]
  }

  # KMS (optional)
  dynamic "statement" {
    for_each = var.kms_key_arn != null ? [1] : []

    content {
      sid    = "AllowKMSForSQS"
      effect = "Allow"

      actions = [
        "kms:Decrypt",
        "kms:GenerateDataKey",
      ]

      resources = [var.kms_key_arn]
    }
  }
}

resource "aws_iam_role_policy" "lambda_permissions" {
  count = var.enable_auto_ingestion ? 1 : 0

  name   = "${var.name}-auto-ingestion-policy"
  role   = aws_iam_role.lambda[0].id
  policy = data.aws_iam_policy_document.lambda_permissions.json
}

# Package the Lambda function inline via archive_file
data "archive_file" "lambda" {
  count = var.enable_auto_ingestion ? 1 : 0

  type        = "zip"
  output_path = "${path.module}/lambda_payload.zip"

  source {
    filename = "handler.py"
    content  = <<-PYTHON
      """
      Auto-ingestion Lambda for Bedrock Knowledge Base.

      Triggered by S3 ObjectCreated events. Calls StartIngestionJob
      to refresh the knowledge base with newly uploaded documents.
      """
      import os
      import json
      import logging
      import boto3
      from botocore.exceptions import ClientError

      logger = logging.getLogger()
      logger.setLevel(logging.INFO)

      KNOWLEDGE_BASE_ID = os.environ["KNOWLEDGE_BASE_ID"]
      DATA_SOURCE_ID = os.environ["DATA_SOURCE_ID"]
      REGION = os.environ.get("AWS_REGION", "us-east-1")

      bedrock_client = boto3.client("bedrock-agent", region_name=REGION)


      def handler(event, context):
          """Handle S3 ObjectCreated notifications and trigger KB ingestion."""
          logger.info("Received event: %s", json.dumps(event))

          records = event.get("Records", [])
          if not records:
              logger.warning("No Records in event; skipping.")
              return {"statusCode": 200, "body": "No records to process."}

          # Deduplicate: one ingestion job per invocation is sufficient
          # because StartIngestionJob scans the full data source.
          keys = [r.get("s3", {}).get("object", {}).get("key", "") for r in records]
          logger.info("Triggering ingestion for %d new S3 object(s): %s", len(keys), keys)

          try:
              response = bedrock_client.start_ingestion_job(
                  knowledgeBaseId=KNOWLEDGE_BASE_ID,
                  dataSourceId=DATA_SOURCE_ID,
                  description=f"Auto-triggered by S3 upload of {len(keys)} object(s)",
              )
              job = response.get("ingestionJob", {})
              job_id = job.get("ingestionJobId", "unknown")
              status = job.get("status", "unknown")
              logger.info("StartIngestionJob succeeded. Job ID: %s, Status: %s", job_id, status)
              return {
                  "statusCode": 200,
                  "body": json.dumps({"ingestionJobId": job_id, "status": status}),
              }

          except ClientError as exc:
              code = exc.response["Error"]["Code"]
              msg = exc.response["Error"]["Message"]
              # ConflictException means a job is already running; log and ignore.
              if code == "ConflictException":
                  logger.info("Ingestion job already in progress (ConflictException). Skipping.")
                  return {"statusCode": 200, "body": "Job already running."}
              logger.error("Bedrock StartIngestionJob failed: %s - %s", code, msg)
              raise
    PYTHON
  }
}

resource "aws_lambda_function" "auto_ingestion" {
  count = var.enable_auto_ingestion ? 1 : 0

  function_name    = "${var.name}-auto-ingestion"
  description      = "Triggers Bedrock Knowledge Base ingestion on S3 uploads for: ${var.name}"
  role             = aws_iam_role.lambda[0].arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.lambda[0].output_path
  source_code_hash = data.archive_file.lambda[0].output_base64sha256
  timeout          = 60
  memory_size      = 128

  reserved_concurrent_executions = var.lambda_reserved_concurrency

  environment {
    variables = {
      KNOWLEDGE_BASE_ID = aws_bedrockagent_knowledge_base.this.id
      DATA_SOURCE_ID    = aws_bedrockagent_data_source.s3.data_source_id
    }
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.lambda_dlq[0].arn
  }

  kms_key_arn = var.kms_key_arn

  tracing_config {
    mode = "Active"
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.lambda_permissions,
  ]

  tags = local.common_tags
}

# Allow S3 to invoke the Lambda
resource "aws_lambda_permission" "s3_invoke" {
  count = var.enable_auto_ingestion ? 1 : 0

  statement_id   = "AllowS3Invoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.auto_ingestion[0].function_name
  principal      = "s3.amazonaws.com"
  source_arn     = "arn:${local.partition}:s3:::${local.s3_bucket_name}"
  source_account = local.account_id
}

# Configure S3 to notify Lambda on object creation
resource "aws_s3_bucket_notification" "auto_ingestion" {
  count = var.enable_auto_ingestion ? 1 : 0

  bucket = local.s3_bucket_name

  lambda_function {
    lambda_function_arn = aws_lambda_function.auto_ingestion[0].arn
    events              = ["s3:ObjectCreated:*"]

    # S3 notifications support a single prefix filter per rule. If multiple
    # s3_inclusion_prefixes are provided, only the first is used here.
    # All prefixes are still passed to the Bedrock data source configuration.
    filter_prefix = length(var.s3_inclusion_prefixes) > 0 ? var.s3_inclusion_prefixes[0] : null
  }

  depends_on = [aws_lambda_permission.s3_invoke]
}
