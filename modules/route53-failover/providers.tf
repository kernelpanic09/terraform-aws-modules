# Default provider configuration for the us_east_1 alias.
# Route 53 health check CloudWatch alarms must be created in us-east-1.
# Callers can override this alias via the providers map:
#
#   module "failover" {
#     source = "..."
#     providers = {
#       aws           = aws
#       aws.us_east_1 = aws.us_east_1
#     }
#   }
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}
