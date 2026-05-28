terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"

      # The replica provider alias is only activated when
      # enable_cross_region_replica = true.
      configuration_aliases = [aws.replica]
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0"
    }
  }
}
