locals {
  common_tags = merge(var.tags, {
    ManagedBy = "terraform"
    Module    = "s3-cloudfront"
  })

  # Custom domain is enabled only when both domain_name and acm_certificate_arn are provided.
  custom_domain_enabled = var.domain_name != null && var.acm_certificate_arn != null

  # Collect all aliases for the distribution.
  aliases = local.custom_domain_enabled ? concat([var.domain_name], var.subject_alternative_names) : []

  # Viewer certificate block is dynamic, so compute a single map to keep main logic readable.
  viewer_certificate = local.custom_domain_enabled ? {
    acm_certificate_arn      = var.acm_certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
    } : {
    acm_certificate_arn      = null
    ssl_support_method       = null
    minimum_protocol_version = "TLSv1.2_2021"
  }

}

# ------------------------------------------------------------------------------
# S3 Bucket
# ------------------------------------------------------------------------------

resource "aws_s3_bucket" "this" {
  bucket = var.name

  # Prevent accidental deletion of a bucket that may hold production content.
  # Set to false only during explicit destroy workflows.
  force_destroy = false

  tags = merge(local.common_tags, { Name = var.name })
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = var.enable_versioning ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.encryption_type
      kms_master_key_id = var.encryption_type == "aws:kms" ? var.kms_key_id : null
    }
    # Bucket-key reduces KMS API call costs when SSE-KMS is used.
    bucket_key_enabled = var.encryption_type == "aws:kms"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle rules use dynamic blocks so callers can supply zero or many rules
# without requiring module changes.
resource "aws_s3_bucket_lifecycle_configuration" "this" {
  count = length(var.lifecycle_rules) > 0 ? 1 : 0

  bucket = aws_s3_bucket.this.id

  dynamic "rule" {
    for_each = var.lifecycle_rules

    content {
      id     = rule.value.id
      status = rule.value.enabled ? "Enabled" : "Disabled"

      filter {
        prefix = rule.value.prefix
      }

      dynamic "expiration" {
        for_each = rule.value.expiration_days != null ? [rule.value.expiration_days] : []
        content {
          days = expiration.value
        }
      }

      dynamic "noncurrent_version_expiration" {
        for_each = rule.value.noncurrent_expiration_days != null ? [rule.value.noncurrent_expiration_days] : []
        content {
          noncurrent_days = noncurrent_version_expiration.value
        }
      }

      dynamic "transition" {
        for_each = rule.value.transition_days != null && rule.value.transition_storage_class != null ? [rule.value] : []
        content {
          days          = transition.value.transition_days
          storage_class = transition.value.transition_storage_class
        }
      }

      dynamic "noncurrent_version_transition" {
        for_each = rule.value.noncurrent_transition_days != null && rule.value.noncurrent_storage_class != null ? [rule.value] : []
        content {
          noncurrent_days = noncurrent_version_transition.value.noncurrent_transition_days
          storage_class   = noncurrent_version_transition.value.noncurrent_storage_class
        }
      }
    }
  }

  # Versioning must be configured before lifecycle rules that reference
  # noncurrent versions; otherwise the API returns an error.
  depends_on = [aws_s3_bucket_versioning.this]
}

# ------------------------------------------------------------------------------
# Bucket Policy. CloudFront OAC Only
#
# The bucket is not publicly accessible. CloudFront presents its service
# principal (cloudfront.amazonaws.com) with a condition on the distribution
# ARN, which is how Origin Access Control (OAC) works. OAC supersedes the
# older Origin Access Identity (OAI) approach and supports SSE-KMS buckets.
# ------------------------------------------------------------------------------

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontOACReadOnly"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.this.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.this.arn
          }
        }
      },
      {
        Sid    = "DenyNonSecureTransport"
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action   = "s3:*"
        Resource = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
    ]
  })

  # The bucket policy references the distribution ARN, so CloudFront must
  # exist first. Public-access block must also be applied before the policy.
  depends_on = [
    aws_s3_bucket_public_access_block.this,
    aws_cloudfront_distribution.this,
  ]
}

# ------------------------------------------------------------------------------
# CloudFront Origin Access Control (OAC)
#
# OAC signs requests to S3 with SigV4, enabling bucket policies to verify
# the exact distribution that sent the request. This replaces the older OAI
# mechanism and is required for SSE-KMS encrypted buckets.
# ------------------------------------------------------------------------------

resource "aws_cloudfront_origin_access_control" "this" {
  name                              = "${var.name}-oac"
  description                       = "OAC for ${var.name} S3 static site"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ------------------------------------------------------------------------------
# CloudFront Function. Directory Index Rewriting
#
# S3 REST API does not serve index.html for key-prefix (directory) requests
# the way the S3 website endpoint does. This CloudFront Function intercepts
# viewer requests and appends /index.html to any URI that ends with / or
# contains no file extension, enabling clean SPA and static-site URLs.
# ------------------------------------------------------------------------------

resource "aws_cloudfront_function" "url_rewrite" {
  name    = "${var.name}-url-rewrite"
  runtime = "cloudfront-js-2.0"
  comment = "Rewrite directory requests to append index.html"
  publish = true

  code = <<-JS
    async function handler(event) {
      var request = event.request;
      var uri = request.uri;

      // Append index.html if the URI ends with a slash.
      if (uri.endsWith('/')) {
        request.uri = uri + 'index.html';
        return request;
      }

      // Append /index.html if the URI has no file extension in the last path segment.
      // This handles clean SPA routes such as /about or /dashboard.
      var lastSegment = uri.split('/').pop();
      if (!lastSegment.includes('.')) {
        request.uri = uri + '/index.html';
      }

      return request;
    }
  JS
}

# ------------------------------------------------------------------------------
# CloudFront Response Headers Policy. Security Headers (optional)
# ------------------------------------------------------------------------------

resource "aws_cloudfront_response_headers_policy" "security" {
  count   = var.enable_security_headers ? 1 : 0
  name    = "${var.name}-security-headers"
  comment = "Security response headers for ${var.name}"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = var.hsts_max_age
      include_subdomains         = true
      preload                    = true
      override                   = true
    }

    content_type_options {
      override = true
    }

    frame_options {
      frame_option = "DENY"
      override     = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }

    xss_protection {
      mode_block = true
      protection = true
      override   = true
    }

    content_security_policy {
      # A strict baseline CSP. Callers running third-party scripts or fonts
      # should override this via a custom response headers policy and set
      # enable_security_headers = false, then manage CSP separately.
      content_security_policy = "default-src 'self'; img-src 'self' data:; script-src 'self'; style-src 'self' 'unsafe-inline';"
      override                = true
    }
  }
}

# ------------------------------------------------------------------------------
# CloudFront Distribution
# ------------------------------------------------------------------------------

resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${var.name} static site"
  default_root_object = "index.html"
  price_class         = var.price_class
  aliases             = local.aliases
  web_acl_id          = var.enable_waf ? aws_wafv2_web_acl.this[0].arn : null

  origin {
    domain_name              = aws_s3_bucket.this.bucket_regional_domain_name
    origin_id                = "s3-${var.name}"
    origin_access_control_id = aws_cloudfront_origin_access_control.this.id
  }

  default_cache_behavior {
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    target_origin_id           = "s3-${var.name}"
    viewer_protocol_policy     = "redirect-to-https"
    compress                   = true
    default_ttl                = var.default_ttl
    min_ttl                    = var.min_ttl
    max_ttl                    = var.max_ttl
    response_headers_policy_id = var.enable_security_headers ? aws_cloudfront_response_headers_policy.security[0].id : null

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.url_rewrite.arn
    }
  }

  # Viewer certificate: ACM cert for custom domain, or CloudFront default cert.
  dynamic "viewer_certificate" {
    for_each = local.custom_domain_enabled ? [local.viewer_certificate] : []
    content {
      acm_certificate_arn      = viewer_certificate.value.acm_certificate_arn
      ssl_support_method       = viewer_certificate.value.ssl_support_method
      minimum_protocol_version = viewer_certificate.value.minimum_protocol_version
    }
  }

  dynamic "viewer_certificate" {
    for_each = local.custom_domain_enabled ? [] : [true]
    content {
      cloudfront_default_certificate = true
      minimum_protocol_version       = "TLSv1.2_2021"
    }
  }

  # Custom error responses support SPA routing and friendly 404 pages.
  dynamic "custom_error_response" {
    for_each = var.custom_error_responses

    content {
      error_code            = custom_error_response.value.error_code
      response_code         = custom_error_response.value.response_code
      response_page_path    = custom_error_response.value.response_page_path
      error_caching_min_ttl = custom_error_response.value.error_caching_min_ttl
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = merge(local.common_tags, { Name = "${var.name}-distribution" })
}

# ------------------------------------------------------------------------------
# WAF Web ACL (optional)
#
# WAFv2 Web ACLs associated with CloudFront must be created in us-east-1.
# If your root provider targets a different region, configure a provider alias
# for us-east-1 and pass it to this module via a provider alias.
#
# Rule evaluation order (priority):
#   0  AWSManagedRulesCommonRuleSet
#   1  AWSManagedRulesKnownBadInputsRuleSet
#   2  RateLimitRule (IP-based, 5-minute window)
# ------------------------------------------------------------------------------

resource "aws_wafv2_web_acl" "this" {
  count = var.enable_waf ? 1 : 0

  name        = "${var.name}-web-acl"
  description = "WAF Web ACL for ${var.name} CloudFront distribution"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # Rule 0: AWS Common Rule Set. protects against OWASP Top 10 threats.
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 0

    override_action {
      # When waf_block_mode = true, override_action = none means each rule's
      # own action (block/count) is respected. Count overrides all to count.
      dynamic "none" {
        for_each = var.waf_block_mode ? [true] : []
        content {}
      }
      dynamic "count" {
        for_each = var.waf_block_mode ? [] : [true]
        content {}
      }
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-CommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # Rule 1: Known Bad Inputs. blocks request patterns known to exploit
  # common vulnerabilities such as Log4JRCE and SSRF.
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 1

    override_action {
      dynamic "none" {
        for_each = var.waf_block_mode ? [true] : []
        content {}
      }
      dynamic "count" {
        for_each = var.waf_block_mode ? [] : [true]
        content {}
      }
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-KnownBadInputs"
      sampled_requests_enabled   = true
    }
  }

  # Rule 2: Rate Limiting. blocks IPs that exceed waf_rate_limit requests
  # in a 5-minute sliding window. Protects against scraping and brute-force.
  rule {
    name     = "RateLimitRule"
    priority = 2

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-RateLimit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-WebACL"
    sampled_requests_enabled   = true
  }

  tags = merge(local.common_tags, { Name = "${var.name}-web-acl" })
}
