# bedrock-knowledge-base

Amazon Bedrock Knowledge Base with OpenSearch Serverless vector store.

## Overview

This module provisions a complete Retrieval-Augmented Generation (RAG) backend:

- **OpenSearch Serverless collection** (vector store) with encryption, network, and data-access policies
- **Bedrock Knowledge Base** wired to the embedding model and the vector index
- **S3 data source** for source documents
- **Optional auto-sync Lambda** that starts an ingestion job when documents change
- **IAM roles** for the knowledge base and the sync Lambda

## Resources Created

| Resource | Purpose |
|----------|---------|
| `aws_opensearchserverless_collection.this` | Vector store |
| `aws_opensearchserverless_security_policy.encryption` | Encryption policy |
| `aws_opensearchserverless_security_policy.network` | Network policy |
| `aws_opensearchserverless_access_policy.data` | Data access policy |
| `aws_bedrockagent_knowledge_base.this` | Knowledge base |
| `aws_bedrockagent_data_source.this` | S3 data source |
| `aws_iam_role.kb` | KB service role |
| `aws_iam_role_policy.kb` | KB inline policy |
| `aws_iam_role.sync_lambda` | Lambda exec role |
| `aws_iam_role_policy.sync_lambda` | Lambda inline policy |
| `aws_lambda_function.sync` | Auto-sync function |
| `archive_file.sync_lambda` (data) | Lambda zip |
| `aws_cloudwatch_log_group.sync_lambda` | Lambda logs |
