# Default provider configuration for the replica alias.
# Cross-region backup vault resources are created in the replica region.
# Callers can override this alias via the providers map:
#
#   module "backup" {
#     source = "..."
#     providers = {
#       aws         = aws
#       aws.replica = aws.replica
#     }
#   }
provider "aws" {
  alias = "replica"
}
