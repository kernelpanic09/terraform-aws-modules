terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# ---------------------------------------------------------------------------
# Providers
#
# CloudFront is a global service, but WAFv2 Web ACLs scoped to CloudFront
# MUST be created in us-east-1. The module targets us-east-1 by default.
# If your infrastructure lives in another region, configure a separate
# provider alias for us-east-1 and pass it to the module.
# ---------------------------------------------------------------------------

provider "aws" {
  region = "us-east-1"
}

# ---------------------------------------------------------------------------
# Example 1: Minimal -- no WAF, no custom domain, SSE-S3 encryption.
#
# Suitable for internal tools, preview environments, or any workload
# where a custom domain and WAF are not yet required.
# ---------------------------------------------------------------------------

module "static_site_minimal" {
  source = "../../modules/s3-cloudfront"

  name = "my-static-site-dev"

  enable_versioning = true
  encryption_type   = "AES256"
  enable_waf        = false

  enable_security_headers = true
  price_class             = "PriceClass_100"

  tags = {
    Environment = "dev"
    Project     = "my-project"
  }
}

output "minimal_site_url" {
  description = "CloudFront URL for the minimal site."
  value       = module.static_site_minimal.site_url
}

output "minimal_bucket_id" {
  description = "S3 bucket name for the minimal site."
  value       = module.static_site_minimal.bucket_id
}

output "minimal_distribution_id" {
  description = "CloudFront distribution ID -- use this for cache invalidations."
  value       = module.static_site_minimal.cloudfront_distribution_id
}

# ---------------------------------------------------------------------------
# Example 2: Production -- custom domain, WAF, SSE-KMS, lifecycle rules.
#
# Assumes the ACM certificate for example.com and www.example.com already
# exists in us-east-1 (CloudFront requirement). The Route 53 ALIAS record
# is created separately (see commented block below).
# ---------------------------------------------------------------------------

# Uncomment and populate to enable the production example.
#
# data "aws_acm_certificate" "site" {
#   domain   = "example.com"
#   statuses = ["ISSUED"]
# }
#
# module "static_site_prod" {
#   source = "../../modules/s3-cloudfront"
#
#   name                      = "my-static-site-prod"
#   domain_name               = "example.com"
#   subject_alternative_names = ["www.example.com"]
#   acm_certificate_arn       = data.aws_acm_certificate.site.arn
#
#   price_class = "PriceClass_100"
#
#   enable_versioning = true
#   encryption_type   = "aws:kms"
#   # kms_key_id = aws_kms_key.s3.arn
#
#   lifecycle_rules = [
#     {
#       id                         = "expire-noncurrent-versions"
#       enabled                    = true
#       prefix                     = ""
#       noncurrent_expiration_days = 30
#     },
#     {
#       id                       = "transition-logs-to-ia"
#       enabled                  = true
#       prefix                   = "logs/"
#       transition_days          = 30
#       transition_storage_class = "STANDARD_IA"
#       expiration_days          = 365
#     },
#   ]
#
#   enable_waf     = true
#   waf_rate_limit = 1000
#   waf_block_mode = true
#
#   enable_security_headers = true
#   hsts_max_age            = 31536000
#
#   default_ttl = 86400    # 1 day
#   max_ttl     = 31536000 # 1 year
#   min_ttl     = 0
#
#   # SPA: send all unresolved paths to index.html with a 200.
#   custom_error_responses = [
#     {
#       error_code            = 403
#       response_code         = 200
#       response_page_path    = "/index.html"
#       error_caching_min_ttl = 10
#     },
#     {
#       error_code            = 404
#       response_code         = 200
#       response_page_path    = "/index.html"
#       error_caching_min_ttl = 10
#     },
#   ]
#
#   tags = {
#     Environment = "prod"
#     Project     = "my-project"
#     CostCenter  = "engineering"
#   }
# }
#
# ---------------------------------------------------------------------------
# Route 53 ALIAS record -- points example.com to CloudFront.
# Uncomment after enabling module.static_site_prod above.
# ---------------------------------------------------------------------------
#
# data "aws_route53_zone" "site" {
#   name         = "example.com."
#   private_zone = false
# }
#
# resource "aws_route53_record" "apex" {
#   zone_id = data.aws_route53_zone.site.zone_id
#   name    = "example.com"
#   type    = "A"
#
#   alias {
#     name                   = module.static_site_prod.cloudfront_domain_name
#     zone_id                = module.static_site_prod.cloudfront_hosted_zone_id
#     evaluate_target_health = false
#   }
# }
#
# resource "aws_route53_record" "www" {
#   zone_id = data.aws_route53_zone.site.zone_id
#   name    = "www.example.com"
#   type    = "A"
#
#   alias {
#     name                   = module.static_site_prod.cloudfront_domain_name
#     zone_id                = module.static_site_prod.cloudfront_hosted_zone_id
#     evaluate_target_health = false
#   }
# }
#
# output "prod_site_url" {
#   value = module.static_site_prod.site_url
# }
#
# output "prod_distribution_id" {
#   value = module.static_site_prod.cloudfront_distribution_id
# }
#
# output "prod_waf_arn" {
#   value = module.static_site_prod.waf_web_acl_arn
# }
