# ------------------------------------------------------------------------------
# S3 Bucket
# ------------------------------------------------------------------------------

output "bucket_id" {
  description = "Name (ID) of the S3 bucket hosting the static site content."
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  description = "ARN of the S3 bucket. Use this when granting cross-account or cross-service access."
  value       = aws_s3_bucket.this.arn
}

output "bucket_regional_domain_name" {
  description = "Regional domain name of the S3 bucket (e.g. my-site.s3.us-east-1.amazonaws.com). Useful when configuring additional CloudFront distributions or custom origins."
  value       = aws_s3_bucket.this.bucket_regional_domain_name
}

# ------------------------------------------------------------------------------
# CloudFront Distribution
# ------------------------------------------------------------------------------

output "cloudfront_distribution_id" {
  description = "ID of the CloudFront distribution. Required for cache invalidation via the AWS CLI: aws cloudfront create-invalidation --distribution-id <id> --paths '/*'."
  value       = aws_cloudfront_distribution.this.id
}

output "cloudfront_distribution_arn" {
  description = "ARN of the CloudFront distribution. Used in WAF Web ACL associations and resource-based policies."
  value       = aws_cloudfront_distribution.this.arn
}

output "cloudfront_domain_name" {
  description = "Default CloudFront domain name assigned to the distribution (e.g. d1234abcd.cloudfront.net). Create a DNS CNAME or ALIAS record pointing your custom domain to this value."
  value       = aws_cloudfront_distribution.this.domain_name
}

output "cloudfront_hosted_zone_id" {
  description = "Route 53 hosted zone ID for the CloudFront distribution. Use this with aws_route53_record alias blocks to create ALIAS records that resolve to the distribution."
  value       = aws_cloudfront_distribution.this.hosted_zone_id
}

output "cloudfront_etag" {
  description = "Current ETag (entity tag) of the CloudFront distribution configuration. Required by some CloudFront API calls that require optimistic concurrency control."
  value       = aws_cloudfront_distribution.this.etag
}

# ------------------------------------------------------------------------------
# CloudFront Function
# ------------------------------------------------------------------------------

output "url_rewrite_function_arn" {
  description = "ARN of the CloudFront Function that rewrites directory URIs to append index.html. Reference this if you add additional cache behaviors and need the same rewrite logic."
  value       = aws_cloudfront_function.url_rewrite.arn
}

# ------------------------------------------------------------------------------
# OAC
# ------------------------------------------------------------------------------

output "origin_access_control_id" {
  description = "ID of the CloudFront Origin Access Control resource. Attach this to additional origins that need authenticated access to the same S3 bucket."
  value       = aws_cloudfront_origin_access_control.this.id
}

# ------------------------------------------------------------------------------
# Security Headers Policy (conditional)
# ------------------------------------------------------------------------------

output "response_headers_policy_id" {
  description = "ID of the CloudFront Response Headers Policy containing security headers. Null when enable_security_headers = false. Use this to attach the same policy to additional cache behaviors."
  value       = var.enable_security_headers ? aws_cloudfront_response_headers_policy.security[0].id : null
}

# ------------------------------------------------------------------------------
# WAF (conditional)
# ------------------------------------------------------------------------------

output "waf_web_acl_arn" {
  description = "ARN of the WAFv2 Web ACL associated with the CloudFront distribution. Null when enable_waf = false. Use this ARN to associate the ACL with additional resources."
  value       = var.enable_waf ? aws_wafv2_web_acl.this[0].arn : null
}

output "waf_web_acl_id" {
  description = "ID of the WAFv2 Web ACL. Null when enable_waf = false."
  value       = var.enable_waf ? aws_wafv2_web_acl.this[0].id : null
}

# ------------------------------------------------------------------------------
# Convenience
# ------------------------------------------------------------------------------

output "site_url" {
  description = "Primary URL at which the site is reachable. Returns the custom domain (with https://) when a domain is configured, otherwise the CloudFront default domain URL."
  value       = local.custom_domain_enabled ? "https://${var.domain_name}" : "https://${aws_cloudfront_distribution.this.domain_name}"
}
