# route53-failover

A Terraform module that implements active-passive multi-region DNS failover using Route53 failover routing policy, health checks, CloudWatch alarms, SNS notifications, and EventBridge event forwarding.

## Architecture

```
                        Route53 Hosted Zone
                               |
              +----------------+----------------+
              |                                 |
    [PRIMARY A/AAAA record]          [SECONDARY A/AAAA record]
    failover = PRIMARY               failover = SECONDARY
    health_check_id = primary_hc     health_check_id = secondary_hc
              |                                 |
     primary_endpoint                 secondary_endpoint
     (us-east-1 ALB, IP, etc.)       (us-west-2 ALB, IP, etc.)

                     Health Checks (from 3 regions)
                     +----------------------------+
                     | us-east-1                  |
                     | eu-west-1                  |
                     | ap-northeast-1             |
                     +----------------------------+
                                  |
                         CloudWatch Metrics
                         (always us-east-1)
                                  |
              +-------------------+-------------------+
              |                   |                   |
    primary_alarm       secondary_alarm        composite_alarm
    (fires on fail)     (fires on fail)        (both down = CRITICAL)
              |                   |                   |
              +-------------------+-------------------+
                                  |
                             SNS Topic
                          (email subscribers)
                                  |
                         EventBridge Rule
                    (Route53 state change events)
```

## Key Design Decisions

**No ALIAS records**: This module uses standard A/AAAA records with explicit IP addresses or FQDNs. It is designed for non-AWS endpoints, on-premises servers, cross-region ALB IPs that you manage, or any scenario where you cannot use an ALIAS record. For AWS-to-AWS failover with ALIAS support, extend this module with an `alias` block.

**Health check placement**: Route53 health checks run from the configured `health_check_regions`. A majority of regions must agree an endpoint is down before it is considered unhealthy. The default is `us-east-1`, `eu-west-1`, and `ap-northeast-1`.

**CloudWatch metrics in us-east-1**: Route53 health check metrics (`AWS/Route53`) are always published to `us-east-1` regardless of where the health check probes originate. The module requires an `aws.us_east_1` provider alias. All alarms, the SNS topic, and the EventBridge rule are created in `us-east-1`.

**Secondary health check**: The secondary record has a `health_check_id` attached. Route53 will attempt to fail back to the primary as soon as it recovers. If you want the secondary to always serve traffic regardless of its own health status, remove `health_check_id` from `aws_route53_record.secondary_a`.

**TTL and failover timing**: With the default TTL of 60 seconds and a failure threshold of 3 at 30-second intervals, the worst-case failover time is approximately `(failure_threshold * request_interval) + TTL = (3 * 30) + 60 = 150 seconds`. Using `request_interval = 10` reduces this to `(3 * 10) + 60 = 90 seconds` at additional cost.

## Provider Configuration

This module requires two provider configurations. The root module must pass both:

```hcl
provider "aws" {
  region = "us-east-1"  # or your default region
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

module "route53_failover" {
  source = "./module"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  # ...
}
```

## Usage

### Basic HTTPS failover

```hcl
module "route53_failover" {
  source = "path/to/route53-failover"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  domain_name    = "example.com"
  hosted_zone_id = "Z1234567890ABC"
  record_name    = "api"
  record_ttl     = 60

  primary_endpoint = {
    address = "1.2.3.4"
    type    = "HTTPS"
    port    = 443
    path    = "/health"
  }

  secondary_endpoint = {
    address = "5.6.7.8"
    type    = "HTTPS"
    port    = 443
    path    = "/health"
  }

  enable_alarms   = true
  alarm_emails    = ["ops@example.com"]
}
```

### HTTPS_STR_MATCH with composite alarm and latency monitoring

```hcl
module "route53_failover" {
  source = "path/to/route53-failover"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  domain_name    = "example.com"
  hosted_zone_id = "Z1234567890ABC"
  record_name    = "api"
  record_ttl     = 30
  request_interval  = 10
  failure_threshold = 2
  measure_latency   = true

  primary_endpoint = {
    address       = "1.2.3.4"
    fqdn          = "primary.example.com"
    type          = "HTTPS_STR_MATCH"
    port          = 443
    path          = "/health"
    search_string = "OK"
  }

  secondary_endpoint = {
    address       = "5.6.7.8"
    fqdn          = "secondary.example.com"
    type          = "HTTPS_STR_MATCH"
    port          = 443
    path          = "/health"
    search_string = "OK"
  }

  health_check_regions = ["us-east-1", "eu-west-1", "ap-northeast-1"]

  enable_alarms           = true
  alarm_emails            = ["ops@example.com", "oncall@example.com"]
  enable_composite_alarm  = true

  enable_calculated_health_check    = true
  calculated_health_check_threshold = 1

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
| aws | >= 5.0.0 |

## Providers

| Name | Version |
|------|---------|
| aws | >= 5.0.0 |
| aws.us_east_1 | >= 5.0.0 |

## Resources Created

| Resource | Count | Condition |
|----------|-------|-----------|
| `aws_route53_health_check.primary` | 1 | always |
| `aws_route53_health_check.secondary` | 1 | always |
| `aws_route53_health_check.calculated` | 0 or 1 | `enable_calculated_health_check = true` |
| `aws_route53_record.primary_a` | 1 | always |
| `aws_route53_record.secondary_a` | 1 | always |
| `aws_route53_record.primary_aaaa` | 0 or 1 | `enable_ipv6 = true` |
| `aws_route53_record.secondary_aaaa` | 0 or 1 | `enable_ipv6 = true` |
| `aws_sns_topic.failover` | 0 or 1 | `enable_alarms = true` |
| `aws_sns_topic_subscription.email` | 0..N | `enable_alarms = true`, per email |
| `aws_sns_topic_policy.failover` | 0 or 1 | `enable_alarms = true` |
| `aws_cloudwatch_metric_alarm.primary_health_check` | 0 or 1 | `enable_alarms = true` |
| `aws_cloudwatch_metric_alarm.secondary_health_check` | 0 or 1 | `enable_alarms = true` |
| `aws_cloudwatch_metric_alarm.primary_latency` | 0 or 1 | `enable_alarms && measure_latency` |
| `aws_cloudwatch_composite_alarm.both_endpoints_down` | 0 or 1 | `enable_alarms && enable_composite_alarm` |
| `aws_cloudwatch_event_rule.health_check_state_change` | 0 or 1 | `enable_alarms && enable_eventbridge_rule` |
| `aws_cloudwatch_event_target.health_check_state_change_sns` | 0 or 1 | `enable_alarms && enable_eventbridge_rule` |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `domain_name` | Apex domain name (e.g. example.com) | `string` | n/a | yes |
| `hosted_zone_id` | Route53 hosted zone ID | `string` | n/a | yes |
| `record_name` | DNS record name relative to the hosted zone | `string` | n/a | yes |
| `record_type` | DNS record type: A or AAAA | `string` | `"A"` | no |
| `record_ttl` | TTL in seconds for DNS records | `number` | `60` | no |
| `enable_ipv6` | Create AAAA records for dual-stack | `bool` | `false` | no |
| `primary_endpoint` | Primary endpoint configuration object | `object` | n/a | yes |
| `primary_ipv6_address` | IPv6 address for the primary endpoint | `string` | `null` | no |
| `secondary_endpoint` | Secondary endpoint configuration object | `object` | n/a | yes |
| `secondary_ipv6_address` | IPv6 address for the secondary endpoint | `string` | `null` | no |
| `health_check_regions` | Regions from which Route53 probes the endpoint | `list(string)` | `["us-east-1", "eu-west-1", "ap-northeast-1"]` | no |
| `failure_threshold` | Consecutive failures before marking unhealthy | `number` | `3` | no |
| `request_interval` | Health check interval in seconds (10 or 30) | `number` | `30` | no |
| `measure_latency` | Enable Route53 latency measurement | `bool` | `false` | no |
| `enable_calculated_health_check` | Create an aggregated calculated health check | `bool` | `false` | no |
| `calculated_health_check_threshold` | Minimum healthy child checks for calculated HC | `number` | `1` | no |
| `enable_alarms` | Create CloudWatch alarms and SNS topic | `bool` | `true` | no |
| `alarm_emails` | Email addresses for SNS subscriptions | `list(string)` | `[]` | no |
| `alarm_evaluation_periods` | Evaluation periods before alarm state change | `number` | `2` | no |
| `enable_composite_alarm` | Create composite alarm for both-down escalation | `bool` | `false` | no |
| `enable_eventbridge_rule` | Forward health state changes to SNS via EventBridge | `bool` | `true` | no |
| `tags` | Tags applied to all resources | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| `primary_health_check_id` | Route53 health check ID for the primary endpoint |
| `primary_health_check_arn` | Route53 health check ARN for the primary endpoint |
| `secondary_health_check_id` | Route53 health check ID for the secondary endpoint |
| `secondary_health_check_arn` | Route53 health check ARN for the secondary endpoint |
| `calculated_health_check_id` | Calculated health check ID (null if disabled) |
| `primary_record_fqdn` | FQDN of the primary A record |
| `secondary_record_fqdn` | FQDN of the secondary A record |
| `primary_record_name` | DNS name of the primary A record |
| `primary_aaaa_record_fqdn` | FQDN of the primary AAAA record (null if IPv6 disabled) |
| `secondary_aaaa_record_fqdn` | FQDN of the secondary AAAA record (null if IPv6 disabled) |
| `sns_topic_arn` | ARN of the failover notification SNS topic |
| `sns_topic_name` | Name of the failover notification SNS topic |
| `primary_alarm_arn` | ARN of the primary health check CloudWatch alarm |
| `secondary_alarm_arn` | ARN of the secondary health check CloudWatch alarm |
| `composite_alarm_arn` | ARN of the composite alarm (null if disabled) |
| `primary_latency_alarm_arn` | ARN of the primary latency alarm (null if disabled) |
| `eventbridge_rule_arn` | ARN of the EventBridge health state change rule |

## Failover Behavior

Route53 evaluates the failover routing policy as follows:

1. Route53 continuously probes both endpoints from the configured `health_check_regions`.
2. When the primary endpoint fails `failure_threshold` consecutive checks from a majority of probe regions, Route53 marks the primary health check as unhealthy.
3. Route53 stops serving the PRIMARY record and begins serving the SECONDARY record for all DNS queries.
4. When the primary recovers, Route53 automatically fails back to the PRIMARY record.

The SECONDARY record has a health check attached in this module. If the secondary is also unhealthy when the primary fails, Route53 will still serve the secondary (it is the last resort). To change this behavior, remove `health_check_id` from the secondary record.

## Cost Notes

- Route53 health checks: $0.50/month per health check (HTTPS) or $0.75/month (STR_MATCH).
- Fast request interval (10s): additional $1.00/month per health check.
- Latency measurement: additional $1.00/month per health check.
- CloudWatch alarms: $0.10/alarm/month.
- SNS: $0.50 per 1 million notifications; email is free.
- EventBridge: first 1 million events/month are free.
