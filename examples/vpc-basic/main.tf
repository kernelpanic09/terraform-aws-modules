provider "aws" {
  region = "us-east-1"
}

module "vpc" {
  source = "../../modules/vpc"

  name               = "production"
  vpc_cidr           = "10.0.0.0/16"
  az_count           = 3
  single_nat_gateway = false
  enable_flow_logs   = true

  tags = {
    Environment = "production"
    Project     = "platform"
  }
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "public_subnets" {
  value = module.vpc.public_subnet_ids
}

output "private_subnets" {
  value = module.vpc.private_subnet_ids
}

output "nat_gateway_ips" {
  description = "Public IPs of NAT Gateways (one per AZ in this config)"
  value       = module.vpc.nat_gateway_ips
}

output "availability_zones" {
  description = "AZs used by the module"
  value       = module.vpc.availability_zones
}
