# bedrock-knowledge-base

Terraform module that provisions a production-grade AWS Bedrock Knowledge Base backed by OpenSearch Serverless for vector storage and S3 for document ingestion.

## Architecture

```
S3 Bucket (documents)
    |
    +-- S3 Event Notification (optional)
    |       |
    |       v
    |   Lambda (auto-ingestion)
    |       |
    |       v
    +-----> Bedrock Knowledge Base
                |
                v
        OpenSearch Serverless (VECTORSEARCH)
                |
         [vector index]
```

The module creates the following AWS resources:

- **OpenSearch Serverless collection** (VECTORSEARCH type) with encryption, network, and data access policies
- **Vector index** inside the collection, created via `null_resource` local-exec (see note below)
- **S3 bucket** for source documents (created if not provided), with versioning, encryption, and block-public-access
- **S3 bucket policy** allowing the Bedrock service principal read access
- **Bedrock Knowledge Base** (`aws_bedrockagent_knowledge_base`) connected to the OpenSearch collection
- **Bedrock Data Source** (`aws_bedrockagent_data_source`) pointing to the S3 bucket
- **IAM service role** for Bedrock with least-privilege permissions
- **OpenSearch data access policy** granting the Bedrock role full index access
- **CloudWatch log groups** for Bedrock and Lambda
- **Lambda function** (optional) that calls `StartIngestionJob` on S3 ObjectCreated events
- **SQS dead-letter queue** (optional) for failed Lambda invocations

## Vector Index Creation Note

OpenSearch Serverless does not have a native Terraform resource for index creation. This module uses a `null_resource` with a `local-exec` provisioner to create the vector index via HTTP after the collection becomes ACTIVE. The machine running `terraform apply` must have:

1. The AWS CLI installed and configured (or environment variables `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and optionally `AWS_SESSION_TOKEN` set).
2. `curl` 7.75 or later (preferred) OR Python 3 with `boto3` installed (used as a fallback).
3. IAM permissions to call `aoss:APIAccessAll` on the collection -- typically the same credentials used for the rest of the Terraform run.

The `null_resource` is idempotent: if the index already exists it logs a message and exits without error. To force recreation of the index, taint the resource:

```bash
terraform taint null_resource.vector_index
terraform apply
```

## Usage

```hcl
module "rag_kb" {
  source = "./module"

  name             = "my-rag-kb"
  embedding_model  = "amazon.titan-embed-text-v2:0"

  chunking_strategy = {
    type               = "FIXED_SIZE"
    max_tokens         = 500
    overlap_percentage = 20
  }

  s3_inclusion_prefixes = ["documents/"]
  enable_auto_ingestion = true

  additional_query_principals = [
    "arn:aws:iam::123456789012:role/developer-role",
  ]

  tags = {
    Environment = "production"
    Team        = "platform"
  }
}
```

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.5.0 |
| aws | >= 5.50.0 |
| null | >= 3.2.0 |
| archive | >= 2.4.0 |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| name | Base name for all resources. 3-32 chars, lowercase letters/numbers/hyphens. | `string` | - | yes |
| embedding_model | Bedrock embedding model ID. | `string` | `"amazon.titan-embed-text-v2:0"` | no |
| chunking_strategy | Document chunking configuration (type, max_tokens, overlap_percentage). | `object` | `{type="FIXED_SIZE", max_tokens=300, overlap_percentage=20}` | no |
| s3_bucket_name | Existing S3 bucket name. Creates a new bucket if null. | `string` | `null` | no |
| s3_inclusion_prefixes | S3 key prefixes to include. Empty list means all objects. | `list(string)` | `[]` | no |
| enable_auto_ingestion | Deploy Lambda to trigger ingestion on S3 ObjectCreated events. | `bool` | `false` | no |
| additional_query_principals | IAM role/user ARNs granted read access to the OpenSearch collection. | `list(string)` | `[]` | no |
| kms_key_arn | Customer-managed KMS key ARN for encryption. AWS-managed if null. | `string` | `null` | no |
| lambda_reserved_concurrency | Reserved Lambda concurrency (-1 = unreserved). | `number` | `5` | no |
| log_retention_days | CloudWatch log retention in days. | `number` | `30` | no |
| tags | Tags applied to all taggable resources. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| knowledge_base_id | Bedrock Knowledge Base ID. |
| knowledge_base_arn | Bedrock Knowledge Base ARN. |
| knowledge_base_name | Bedrock Knowledge Base name. |
| data_source_id | Bedrock Data Source ID. |
| opensearch_collection_id | OpenSearch Serverless collection ID. |
| opensearch_collection_arn | OpenSearch Serverless collection ARN. |
| opensearch_collection_endpoint | HTTPS endpoint for direct OpenSearch API access. |
| opensearch_dashboard_endpoint | OpenSearch Dashboards URL. |
| vector_index_name | Name of the created vector index. |
| s3_bucket_name | Document source S3 bucket name. |
| s3_bucket_arn | Document source S3 bucket ARN. |
| s3_bucket_created | Whether the module created the S3 bucket. |
| bedrock_role_arn | Bedrock service role ARN. |
| bedrock_role_name | Bedrock service role name. |
| lambda_function_arn | Auto-ingestion Lambda ARN (null if disabled). |
| lambda_function_name | Auto-ingestion Lambda name (null if disabled). |
| lambda_dlq_arn | Lambda dead-letter queue ARN (null if disabled). |
| lambda_dlq_url | Lambda dead-letter queue URL (null if disabled). |
| bedrock_log_group_name | Bedrock CloudWatch log group name. |
| lambda_log_group_name | Lambda CloudWatch log group name (null if disabled). |
| retrieve_and_generate_config | Convenience map with IDs needed for Bedrock RetrieveAndGenerate API calls. |

## Embedding Models

| Model ID | Dimensions | Notes |
|----------|-----------|-------|
| `amazon.titan-embed-text-v2:0` | 1024 | Recommended default, supports dimension reduction |
| `amazon.titan-embed-text-v1:2:8k` | 1536 | Legacy Titan v1 |
| `cohere.embed-english-v3` | 1024 | English-only, strong retrieval performance |
| `cohere.embed-multilingual-v3` | 1024 | 100+ language support |

## Chunking Strategies

| Strategy | Description | Required fields |
|----------|-------------|-----------------|
| `FIXED_SIZE` | Split by token count with overlap | max_tokens, overlap_percentage |
| `SEMANTIC` | Split at semantic boundaries using ML | none |
| `HIERARCHICAL` | Parent/child chunks for multi-level retrieval | none |
| `NONE` | Treat each document as a single chunk | none |

## Ingesting Documents

Upload documents to the S3 bucket:

```bash
aws s3 cp my-document.pdf s3://<s3_bucket_name>/documents/
```

Trigger a manual ingestion job:

```bash
aws bedrock-agent start-ingestion-job \
  --knowledge-base-id <knowledge_base_id> \
  --data-source-id <data_source_id>
```

Query the knowledge base:

```bash
aws bedrock-agent-runtime retrieve \
  --knowledge-base-id <knowledge_base_id> \
  --retrieval-query '{"text": "What is the refund policy?"}'
```

## Auto-Ingestion

When `enable_auto_ingestion = true`, an S3 event notification triggers a Lambda function on every `s3:ObjectCreated:*` event. The Lambda calls `bedrock-agent.start_ingestion_job`. Note:

- Bedrock allows only one ingestion job per data source at a time. The Lambda handles `ConflictException` gracefully by logging and exiting without error.
- If multiple files are uploaded simultaneously, each ObjectCreated event triggers the Lambda independently. The second and subsequent jobs that arrive while one is running are silently skipped.
- Check the Lambda dead-letter queue for any failed invocations.
- Lambda X-Ray active tracing is enabled.

## Security

- The S3 bucket enforces HTTPS-only access via a bucket policy `Deny` on `aws:SecureTransport = false`.
- The Bedrock service role trust policy uses `aws:SourceAccount` and `aws:SourceArn` conditions to prevent confused-deputy attacks.
- The S3 bucket policy restricts Bedrock access to the current account and knowledge bases in the current region.
- OpenSearch collection access is controlled by both the network policy (endpoint exposure) and the data access policy (IAM-based authorization). The network policy uses `AllowFromPublic: true` so the Bedrock service can reach the endpoint -- access is still gated by the data access policy. For stricter isolation, configure a VPC endpoint and update the network policy accordingly.

## Limitations

- S3 bucket notifications support only one filter prefix. If `s3_inclusion_prefixes` contains multiple entries, only the first prefix is used for the Lambda trigger filter. All prefixes are still passed to the Bedrock data source configuration.
- Recreating the OpenSearch Serverless collection requires tainting both `aws_opensearchserverless_collection.this` and `null_resource.vector_index`.
- The `null_resource` provisioner runs on the machine executing `terraform apply`, not inside AWS. Ensure the executing environment has the required tools and credentials.
