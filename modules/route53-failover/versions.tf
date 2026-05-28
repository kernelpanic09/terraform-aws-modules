terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
      # configuration_aliases declares the provider aliases this module expects
      # the caller to pass via the `providers` map. The us_east_1 alias is
      # required because Route53 CloudWatch metrics are always published to
      # us-east-1, so alarms, SNS topics, and EventBridge rules must be
      # created there regardless of the caller's default region.
      configuration_aliases = [aws.us_east_1]
    }
  }
}
