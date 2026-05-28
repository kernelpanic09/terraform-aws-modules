# terraform-aws-s3-cloudfront

A production-grade Terraform module that provisions a secure, globally distributed static
site on AWS using S3 and CloudFront with Origin Access Control (OAC). Optional WAF
protection and custom domain support are included.

## Architecture

```
Browser
  |
  v
CloudFront Distribution
  |-- CloudFront Function (URL rewrite: /about -> /about/index.html)
  |-- Response Headers Policy (HSTS, X-Frame-Options, CSP, ...)   [optional]
  |-- WAF Web ACL (Common + KnownBadInputs + rate-limit)          [optional]
  |
  v
S3 Bucket (private, OAC-only access)
  |-- SSE-S3 or SSE-KMS encryption
  |-- Versioning
  |-- Lifecycle rules
  |-- Public access block (all four flags enabled)
```

**Why OAC instead of OAI?**
Origin Access Control (OAC) was introduced in 2022 as the successor to Origin Access
Identity (OAI). OAC signs requests with SigV4 instead of a shared credential, supports
SSE-KMS encrypted buckets, and follows AWS's recommended security baseline. OAI is
considered legacy and has no new feature development.

## Features

- S3 bucket with configurable versioning, SSE-S3 or SSE-KMS encryption, and lifecycle rules
- Private bucket policy that allows only the specific CloudFront distribution via OAC
  (enforced by `AWS:SourceArn` condition); denies non-TLS transport to all principals
- CloudFront distribution with:
  - OAC-based origin (not OAI)
  - TLS minimum version TLSv1.2_2021
  - Configurable price class
  - Optional custom domain + ACM certificate
  - Configurable default, min, and max TTLs
  - SPA-friendly custom error responses (403/404 -> index.html with 200)
  - IPv6 enabled
  - Compression enabled
- CloudFront Function (cloudfront-js-2.0 runtime) that rewrites directory URIs by
  appending `index.html`, solving the S3 REST API limitation without requiring the
  S3 website endpoint
- Optional Response Headers Policy: HSTS, X-Content-Type-Options, X-Frame-Options,
  Referrer-Policy, XSS-Protection, and a baseline Content-Security-Policy
- Optional WAFv2 Web ACL:
  - `AWSManagedRulesCommonRuleSet` (OWASP Top 10 mitigations)
  - `AWSManagedRulesKnownBadInputsRuleSet` (Log4Shell, SSRF, etc.)
  - IP-based rate-limiting rule (configurable threshold, 5-minute window)
  - Block or Count mode toggle for safe rollout

## Usage

### Minimal (no custom domain, no WAF)

```hcl
module "static_site" {
  source = "github.com/your-org/terraform-aws-modules//modules/s3-cloudfront"

  name = "my-static-site"

  tags = {
    Environment = "dev"
    Project     = "my-project"
  }
}

output "site_url" {
  value = module.static_site.site_url
}

output "distribution_id" {
  value = module.static_site.cloudfront_distribution_id
}
```

### Production (custom domain, WAF, SSE-KMS)

```hcl
data "aws_acm_certificate" "site" {
  domain   = "example.com"
  statuses = ["ISSUED"]
}

module "static_site" {
  source = "github.com/your-org/terraform-aws-modules//modules/s3-cloudfront"

  name                      = "my-static-site-prod"
  domain_name               = "example.com"
  subject_alternative_names = ["www.example.com"]
  acm_certificate_arn       = data.aws_acm_certificate.site.arn

  price_class = "PriceClass_100"

  enable_versioning = true
  encryption_type   = "aws:kms"
  kms_key_id        = aws_kms_key.s3.arn

  lifecycle_rules = [
    {
      id                         = "expire-noncurrent"
      noncurrent_expiration_days = 30
    },
  ]

  enable_waf     = true
  waf_rate_limit = 1000
  waf_block_mode = true

  enable_security_headers = true

  tags = {
    Environment = "prod"
    Project     = "my-project"
  }
}

# Point the apex domain to CloudFront with a Route 53 ALIAS record.
resource "aws_route53_record" "apex" {
  zone_id = data.aws_route53_zone.site.zone_id
  name    = "example.com"
  type    = "A"

  alias {
    name                   = module.static_site.cloudfront_domain_name
    zone_id                = module.static_site.cloudfront_hosted_zone_id
    evaluate_target_health = false
  }
}
```

### Deploying content

After `terraform apply`, upload your build artifacts and invalidate the CloudFront cache:

```bash
aws s3 sync ./dist s3://$(terraform output -raw bucket_id) --delete

aws cloudfront create-invalidation \
  --distribution-id $(terraform output -raw distribution_id) \
  --paths "/*"
```

## Regional note for WAF

WAFv2 Web ACLs associated with CloudFront must exist in `us-east-1`. If your
infrastructure is in another region, configure a provider alias:

```hcl
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

# The module itself does not accept a provider argument because Terraform
# does not support passing provider aliases into child modules for individual
# resources. Deploy this module with the us-east-1 provider as your default,
# or split WAF management into a separate root module targeting us-east-1.
```

## Requirements

| Name      | Version   |
|-----------|-----------|
| terraform | >= 1.5    |
| aws       | >= 5.0    |

## Variables

| Name                      | Type           | Default           | Description |
|---------------------------|----------------|-------------------|-------------|
| `name`                    | `string`       | required          | Name prefix for all resources. Must follow S3 bucket naming rules (3-63 chars, lowercase alphanumeric and hyphens). |
| `tags`                    | `map(string)`  | `{}`              | Additional tags merged onto all taggable resources. |
| `domain_name`             | `string`       | `null`            | Primary custom domain (e.g. `example.com`). Requires `acm_certificate_arn`. |
| `subject_alternative_names` | `list(string)` | `[]`            | Additional domains (e.g. `["www.example.com"]`) added to the distribution aliases. |
| `acm_certificate_arn`     | `string`       | `null`            | ACM certificate ARN in `us-east-1`. Required when `domain_name` is set. |
| `price_class`             | `string`       | `"PriceClass_100"` | CloudFront price class. One of `PriceClass_100`, `PriceClass_200`, `PriceClass_All`. |
| `default_ttl`             | `number`       | `86400`           | Default cache TTL in seconds when origin does not set cache headers. |
| `min_ttl`                 | `number`       | `0`               | Minimum cache TTL in seconds. |
| `max_ttl`                 | `number`       | `31536000`        | Maximum cache TTL in seconds. |
| `custom_error_responses`  | `list(object)` | 403+404 to index.html | Custom error response rules. Set to `[]` to disable. |
| `enable_security_headers` | `bool`         | `true`            | Attach a Response Headers Policy with HSTS, CSP, and other security headers. |
| `hsts_max_age`            | `number`       | `31536000`        | HSTS `max-age` in seconds. Only applies when `enable_security_headers = true`. |
| `enable_versioning`       | `bool`         | `true`            | Enable S3 object versioning on the bucket. |
| `encryption_type`         | `string`       | `"AES256"`        | S3 SSE algorithm. `"AES256"` for SSE-S3 or `"aws:kms"` for SSE-KMS. |
| `kms_key_id`              | `string`       | `null`            | KMS key ARN or alias. Required when `encryption_type = "aws:kms"`. |
| `lifecycle_rules`         | `list(object)` | expire noncurrent after 30d | S3 lifecycle rules. See variable description for full schema. |
| `enable_waf`              | `bool`         | `false`           | Create and associate a WAFv2 Web ACL with the distribution. |
| `waf_rate_limit`          | `number`       | `2000`            | Max requests per IP per 5-minute window before WAF blocks. Minimum 100. |
| `waf_block_mode`          | `bool`         | `true`            | When `true`, managed rules block matching requests. When `false`, rules count only (safe rollout mode). |

## Outputs

| Name                          | Description |
|-------------------------------|-------------|
| `bucket_id`                   | S3 bucket name. |
| `bucket_arn`                  | S3 bucket ARN. |
| `bucket_regional_domain_name` | S3 regional domain name. |
| `cloudfront_distribution_id`  | CloudFront distribution ID (used for cache invalidations). |
| `cloudfront_distribution_arn` | CloudFront distribution ARN. |
| `cloudfront_domain_name`      | CloudFront default domain (e.g. `d1234abcd.cloudfront.net`). Use as CNAME/ALIAS target. |
| `cloudfront_hosted_zone_id`   | Route 53 hosted zone ID for CloudFront ALIAS records. |
| `cloudfront_etag`             | ETag of the distribution configuration. |
| `url_rewrite_function_arn`    | ARN of the CloudFront Function for directory index rewriting. |
| `origin_access_control_id`    | OAC resource ID. |
| `response_headers_policy_id`  | Security headers policy ID (null when `enable_security_headers = false`). |
| `waf_web_acl_arn`             | WAF Web ACL ARN (null when `enable_waf = false`). |
| `waf_web_acl_id`              | WAF Web ACL ID (null when `enable_waf = false`). |
| `site_url`                    | Primary site URL (`https://custom-domain` or `https://cloudfront-domain`). |

## Security considerations

- The S3 bucket has all four public-access block settings enabled. Content is never
  directly reachable from the internet; all traffic must flow through CloudFront.
- The bucket policy includes a `DenyNonSecureTransport` statement that blocks any
  request using plain HTTP, including AWS SDK calls that do not enforce TLS.
- CloudFront enforces `redirect-to-https` on the viewer-facing side, so HTTP visitors
  are automatically upgraded to HTTPS.
- The minimum TLS version is set to `TLSv1.2_2021`, which disables TLS 1.0 and 1.1.
- When `enable_security_headers = true`, the HSTS header includes `includeSubDomains`
  and `preload`. Ensure all subdomains also support HTTPS before enabling preload.
- The default CSP is intentionally strict. If your SPA loads resources from external
  origins (CDNs, fonts, analytics), you will need to customize the CSP. Set
  `enable_security_headers = false` and manage a `aws_cloudfront_response_headers_policy`
  resource directly in your root module.
- WAF managed rule groups in Block mode may produce false positives. Start with
  `waf_block_mode = false` to review Count metrics in CloudWatch before enforcing.

## Examples

See [`examples/s3-static-site/main.tf`](../../examples/s3-static-site/main.tf) for a
runnable example covering both a minimal deployment and a fully-configured production
setup with custom domain, WAF, SSE-KMS, and Route 53 ALIAS records.
