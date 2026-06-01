# ---------------------------------------------------------------------------
# Example: route53-failover module
#
# Demonstrates active-passive DNS failover between two ALB endpoints:
#   Primary:   api-primary.example.com (us-east-1 ALB)
#   Secondary: api-secondary.example.com (us-west-2 ALB)
#
# Health check type: HTTPS_STR_MATCH (looks for "OK" in response body)
# Probe regions: us-east-1, eu-west-1, ap-northeast-1
# Alarms: email notification + composite escalation alarm
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
  }
}

# ---------------------------------------------------------------------------
# Providers
#
# Route53 CloudWatch metrics are always published to us-east-1.
# Both provider configurations are required by the module.
# ---------------------------------------------------------------------------

provider "aws" {
  region = var.primary_region

  default_tags {
    tags = local.default_tags
  }
}

# The module creates all alarms, SNS topics, and EventBridge rules in
# us-east-1 via this alias. Even if your primary region is already
# us-east-1, the alias must be declared.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = local.default_tags
  }
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "primary_region" {
  description = "AWS region for the primary ALB and Route53 operations."
  type        = string
  default     = "us-east-1"
}

variable "secondary_region" {
  description = "AWS region for the secondary (failover) ALB."
  type        = string
  default     = "us-west-2"
}

variable "domain_name" {
  description = "The apex domain name whose hosted zone will contain the failover records."
  type        = string
  # Example: "example.com"
}

variable "hosted_zone_id" {
  description = "The Route53 hosted zone ID for the domain."
  type        = string
  # Example: "Z1234567890ABCDEFGHIJ"
}

variable "record_name" {
  description = "The DNS record name to create (relative label, e.g. 'api')."
  type        = string
  default     = "api"
}

variable "primary_alb_dns_name" {
  description = "DNS name of the primary ALB (us-east-1). Used as the FQDN in the health check."
  type        = string
  # Example: "my-alb-1234567890.us-east-1.elb.amazonaws.com"
}

variable "primary_alb_ip" {
  description = "A stable IP address or the resolved IP of the primary ALB for the A record. In practice use a static IP, NLB IP, or a VIP."
  type        = string
  # Example: "203.0.113.10"
}

variable "secondary_alb_dns_name" {
  description = "DNS name of the secondary ALB (us-west-2). Used as the FQDN in the health check."
  type        = string
  # Example: "my-alb-0987654321.us-west-2.elb.amazonaws.com"
}

variable "secondary_alb_ip" {
  description = "A stable IP address for the secondary ALB A record."
  type        = string
  # Example: "203.0.113.20"
}

variable "alarm_emails" {
  description = "Email addresses that will receive SNS notifications on health check failures."
  type        = list(string)
  default     = ["ops@example.com"]
}

variable "environment" {
  description = "Deployment environment label (production, staging, etc.)."
  type        = string
  default     = "production"
}

# ---------------------------------------------------------------------------
# Locals
# ---------------------------------------------------------------------------

locals {
  default_tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Module      = "route53-failover-example"
    Domain      = var.domain_name
  }
}

# ---------------------------------------------------------------------------
# Module invocation
# ---------------------------------------------------------------------------

module "api_failover" {
  source = "../../modules/route53-failover"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  # Core DNS settings
  domain_name    = var.domain_name
  hosted_zone_id = var.hosted_zone_id
  record_name    = var.record_name
  record_ttl     = 30 # low TTL for fast client-side propagation

  # Health check tuning
  # request_interval = 10 gives ~90s worst-case failover; costs $1/month extra per check.
  # request_interval = 30 gives ~150s worst-case failover; standard pricing.
  request_interval  = 10
  failure_threshold = 2
  measure_latency   = true

  health_check_regions = [
    "us-east-1",
    "eu-west-1",
    "ap-northeast-1",
  ]

  # Primary endpoint: us-east-1 ALB
  # type = HTTPS_STR_MATCH: Route53 checks that the response body contains "OK"
  # fqdn is set so Route53 sends the correct SNI header for HTTPS
  primary_endpoint = {
    address       = var.primary_alb_ip
    fqdn          = var.primary_alb_dns_name
    type          = "HTTPS_STR_MATCH"
    port          = 443
    path          = "/health"
    search_string = "OK"
  }

  # Secondary endpoint: us-west-2 ALB (passive failover target)
  secondary_endpoint = {
    address       = var.secondary_alb_ip
    fqdn          = var.secondary_alb_dns_name
    type          = "HTTPS_STR_MATCH"
    port          = 443
    path          = "/health"
    search_string = "OK"
  }

  # Alarm configuration
  enable_alarms            = true
  alarm_emails             = var.alarm_emails
  alarm_evaluation_periods = 2

  # Composite alarm fires only when BOTH endpoints are down (total outage).
  # This is the escalation signal for paging on-call engineers.
  enable_composite_alarm = true

  # EventBridge rule forwards Route53 health state change events to SNS.
  # This catches transitions that CloudWatch alarms may lag behind on.
  enable_eventbridge_rule = true

  # Calculated health check: aggregates both endpoint checks into one.
  # Useful for attaching to dashboards or other automation.
  enable_calculated_health_check    = true
  calculated_health_check_threshold = 1 # healthy if at least 1 of 2 endpoints is up

  tags = {
    Environment = var.environment
    Team        = "platform"
    CostCenter  = "infra"
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "primary_record_fqdn" {
  description = "FQDN of the primary A record. DNS queries resolve to the primary ALB IP when healthy."
  value       = module.api_failover.primary_record_fqdn
}

output "secondary_record_fqdn" {
  description = "FQDN of the secondary A record. DNS queries resolve here when the primary is unhealthy."
  value       = module.api_failover.secondary_record_fqdn
}

output "primary_health_check_id" {
  description = "Route53 health check ID for the primary endpoint."
  value       = module.api_failover.primary_health_check_id
}

output "secondary_health_check_id" {
  description = "Route53 health check ID for the secondary endpoint."
  value       = module.api_failover.secondary_health_check_id
}

output "calculated_health_check_id" {
  description = "Aggregated calculated health check ID."
  value       = module.api_failover.calculated_health_check_id
}

output "sns_topic_arn" {
  description = "SNS topic ARN for failover notifications."
  value       = module.api_failover.sns_topic_arn
}

output "primary_alarm_arn" {
  description = "CloudWatch alarm ARN for primary endpoint health check failures."
  value       = module.api_failover.primary_alarm_arn
}

output "secondary_alarm_arn" {
  description = "CloudWatch alarm ARN for secondary endpoint health check failures."
  value       = module.api_failover.secondary_alarm_arn
}

output "composite_alarm_arn" {
  description = "Composite CloudWatch alarm ARN (fires when both endpoints are down)."
  value       = module.api_failover.composite_alarm_arn
}

output "eventbridge_rule_arn" {
  description = "EventBridge rule ARN for Route53 health check state change events."
  value       = module.api_failover.eventbridge_rule_arn
}

output "health_check_console_url" {
  description = "Direct link to the Route53 health checks console."
  value       = "https://console.aws.amazon.com/route53/healthchecks/home"
}

output "cloudwatch_alarms_console_url" {
  description = "Direct link to the CloudWatch alarms console (us-east-1 where Route53 metrics live)."
  value       = "https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#alarmsV2:"
}
