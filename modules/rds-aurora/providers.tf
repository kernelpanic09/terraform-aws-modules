# Default provider configuration for the replica alias.
# Cross-region Aurora replica resources are created in the replica region.
# Callers can override this alias via the providers map:
#
#   module "aurora" {
#     source = "..."
#     providers = {
#       aws         = aws
#       aws.replica = aws.replica
#     }
#   }
provider "aws" {
  alias = "replica"
}
