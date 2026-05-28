variable "name" {
  description = "Base name for all resources. Used as prefix for IAM roles, S3 bucket, OpenSearch collection, etc."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3-32 characters, start with a lowercase letter, contain only lowercase letters, numbers, and hyphens, and not end with a hyphen."
  }
}

variable "embedding_model" {
  description = "Bedrock foundation model ID for text embeddings. Must be an embedding model available in the deployment region."
  type        = string
  default     = "amazon.titan-embed-text-v2:0"

  validation {
    condition = contains([
      "amazon.titan-embed-text-v2:0",
      "amazon.titan-embed-text-v1:2:8k",
      "cohere.embed-english-v3",
      "cohere.embed-multilingual-v3",
    ], var.embedding_model)
    error_message = "embedding_model must be one of: amazon.titan-embed-text-v2:0, amazon.titan-embed-text-v1:2:8k, cohere.embed-english-v3, cohere.embed-multilingual-v3."
  }
}

variable "chunking_strategy" {
  description = "Document chunking configuration for the Bedrock data source."
  type = object({
    type               = string
    max_tokens         = optional(number, 300)
    overlap_percentage = optional(number, 20)
  })
  default = {
    type               = "FIXED_SIZE"
    max_tokens         = 300
    overlap_percentage = 20
  }

  validation {
    condition = contains(
      ["FIXED_SIZE", "SEMANTIC", "HIERARCHICAL", "NONE"],
      var.chunking_strategy.type
    )
    error_message = "chunking_strategy.type must be one of: FIXED_SIZE, SEMANTIC, HIERARCHICAL, NONE."
  }

  validation {
    condition = (
      var.chunking_strategy.type != "FIXED_SIZE" ||
      (var.chunking_strategy.max_tokens >= 20 && var.chunking_strategy.max_tokens <= 8192)
    )
    error_message = "chunking_strategy.max_tokens must be between 20 and 8192 when type is FIXED_SIZE."
  }

  validation {
    condition = (
      var.chunking_strategy.type != "FIXED_SIZE" ||
      (var.chunking_strategy.overlap_percentage >= 1 && var.chunking_strategy.overlap_percentage <= 99)
    )
    error_message = "chunking_strategy.overlap_percentage must be between 1 and 99 when type is FIXED_SIZE."
  }
}

variable "s3_bucket_name" {
  description = "Name of an existing S3 bucket to use as the document source. If null or empty, a new bucket will be created with the pattern '<name>-kb-docs-<account_id>'."
  type        = string
  default     = null

  validation {
    condition = (
      var.s3_bucket_name == null ||
      can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.s3_bucket_name))
    )
    error_message = "s3_bucket_name must be a valid S3 bucket name (3-63 characters, lowercase letters, numbers, hyphens, and dots)."
  }
}

variable "s3_inclusion_prefixes" {
  description = "List of S3 key prefixes to include in the knowledge base data source. Empty list means all objects in the bucket are included."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.s3_inclusion_prefixes) <= 25
    error_message = "s3_inclusion_prefixes may contain at most 25 entries."
  }
}

variable "enable_auto_ingestion" {
  description = "When true, a Lambda function is deployed that triggers StartIngestionJob whenever new objects are uploaded to the S3 bucket."
  type        = bool
  default     = false
}

variable "additional_query_principals" {
  description = "List of IAM principal ARNs (users, roles) that will be granted read/query access to the OpenSearch Serverless collection."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for arn in var.additional_query_principals :
      can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(role|user)/", arn))
    ])
    error_message = "All additional_query_principals must be valid IAM role or user ARNs in the format arn:aws:iam::<account_id>:(role|user)/<name>."
  }
}

variable "kms_key_arn" {
  description = "ARN of a customer-managed KMS key for encrypting the S3 bucket and OpenSearch Serverless collection. When null, AWS-owned/managed encryption is used."
  type        = string
  default     = null

  validation {
    condition = (
      var.kms_key_arn == null ||
      can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[a-f0-9-]{36}$", var.kms_key_arn))
    )
    error_message = "kms_key_arn must be a valid KMS key ARN in the format arn:aws:kms:<region>:<account_id>:key/<uuid>."
  }
}

variable "lambda_reserved_concurrency" {
  description = "Reserved concurrency for the auto-ingestion Lambda. Set to -1 to use unreserved concurrency. Only relevant when enable_auto_ingestion is true."
  type        = number
  default     = 5

  validation {
    condition     = var.lambda_reserved_concurrency == -1 || (var.lambda_reserved_concurrency >= 0 && var.lambda_reserved_concurrency <= 1000)
    error_message = "lambda_reserved_concurrency must be -1 (unreserved) or between 0 and 1000."
  }
}

variable "log_retention_days" {
  description = "Number of days to retain CloudWatch log events."
  type        = number
  default     = 30

  validation {
    condition = contains(
      [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.log_retention_days
    )
    error_message = "log_retention_days must be a CloudWatch-supported retention period."
  }
}

variable "tags" {
  description = "Map of tags to apply to all taggable resources."
  type        = map(string)
  default     = {}
}
