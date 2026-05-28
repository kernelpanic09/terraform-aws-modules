terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# ---------------------------------------------------------------------------
# This example wires up a classic hub-and-spoke pattern with three VPCs:
#
#   shared-services   acts as the hub (internet egress, DNS, secrets, etc.)
#   prod              workload VPC, traffic-isolated from non-prod
#   non-prod          workload VPC, traffic-isolated from prod
#
# Route table layout:
#
#   shared-services RT   all VPC CIDRs propagated here, plus default route back
#                        to shared-services attachment for its own traffic.
#   prod RT              shared-services CIDR propagated here + 0.0.0.0/0 static
#                        pointing to the shared-services attachment (centralized
#                        egress). Prod does NOT see non-prod routes.
#   non-prod RT          same as prod but separate RT. Non-prod does NOT see prod.
#
# Effective reachability matrix:
#
#   shared-services  -> prod          YES (propagated into shared-services RT)
#   shared-services  -> non-prod      YES (propagated into shared-services RT)
#   prod             -> shared-svcs   YES (propagated into prod RT) + egress via 0/0
#   prod             -> non-prod      NO  (non-prod doesn't propagate into prod RT)
#   non-prod         -> shared-svcs   YES (propagated into non-prod RT) + egress
#   non-prod         -> prod          NO  (prod doesn't propagate into non-prod RT)
# ---------------------------------------------------------------------------

# Placeholder data sources. In a real deployment these would be real VPC/subnet IDs.
# Replace these with actual resource references or data lookups.
variable "shared_services_vpc_id" {
  default = "vpc-0shared0000000001"
}
variable "shared_services_subnet_ids" {
  default = ["subnet-0shared000000001a", "subnet-0shared000000001b"]
}
variable "prod_vpc_id" {
  default = "vpc-0prod000000000001"
}
variable "prod_subnet_ids" {
  default = ["subnet-0prod0000000001a", "subnet-0prod0000000001b"]
}
variable "non_prod_vpc_id" {
  default = "vpc-0nonprod00000001"
}
variable "non_prod_subnet_ids" {
  default = ["subnet-0nonprod000001a", "subnet-0nonprod000001b"]
}

module "tgw" {
  source = "../module"

  name            = "corp-hub"
  amazon_side_asn = 64512

  # ---------------------------------------------------------------------------
  # Route tables
  # ---------------------------------------------------------------------------
  route_tables = [
    {
      name = "shared-services"
      tags = { Tier = "shared" }
    },
    {
      name = "prod"
      tags = { Tier = "prod" }
    },
    {
      name = "non-prod"
      tags = { Tier = "non-prod" }
    },
  ]

  # ---------------------------------------------------------------------------
  # VPC attachments
  # ---------------------------------------------------------------------------
  vpc_attachments = [
    {
      # Hub. Propagated to every route table so all workload VPCs can reach
      # shared-services. Associated to its own RT so it can reach all spokes.
      name                     = "shared-services"
      vpc_id                   = var.shared_services_vpc_id
      subnet_ids               = var.shared_services_subnet_ids
      route_table_association  = "shared-services"
      route_table_propagations = ["shared-services", "prod", "non-prod"]
      dns_support              = true
      appliance_mode_support   = true # needed if you run a firewall/NAT here
      tags                     = { Role = "hub" }
    },
    {
      # Prod spoke. Only propagates into shared-services RT (not non-prod RT).
      name                     = "prod"
      vpc_id                   = var.prod_vpc_id
      subnet_ids               = var.prod_subnet_ids
      route_table_association  = "prod"
      route_table_propagations = ["shared-services"]
      dns_support              = true
      tags                     = { Role = "spoke", Tier = "prod" }
    },
    {
      # Non-prod spoke. Only propagates into shared-services RT (not prod RT).
      name                     = "non-prod"
      vpc_id                   = var.non_prod_vpc_id
      subnet_ids               = var.non_prod_subnet_ids
      route_table_association  = "non-prod"
      route_table_propagations = ["shared-services"]
      dns_support              = true
      tags                     = { Role = "spoke", Tier = "non-prod" }
    },
  ]

  # ---------------------------------------------------------------------------
  # Static routes
  #
  # 0.0.0.0/0 in both workload route tables points to the shared-services
  # attachment. This is the centralized egress pattern: prod and non-prod VPCs
  # reach the internet through a NAT Gateway (or firewall) in shared-services,
  # not through their own IGWs.
  # ---------------------------------------------------------------------------
  static_routes = [
    {
      route_table_name       = "prod"
      destination_cidr_block = "0.0.0.0/0"
      attachment_name        = "shared-services"
      blackhole              = false
    },
    {
      route_table_name       = "non-prod"
      destination_cidr_block = "0.0.0.0/0"
      attachment_name        = "shared-services"
      blackhole              = false
    },
  ]

  # ---------------------------------------------------------------------------
  # RAM: share the TGW with the whole AWS Organization so member accounts can
  # accept attachments without manual approval.
  # ---------------------------------------------------------------------------
  enable_ram_sharing      = true
  share_with_organization = true

  # ---------------------------------------------------------------------------
  # Optional: enable flow logs. Uncomment and set the destination ARN to use.
  # ---------------------------------------------------------------------------
  # enable_flow_logs           = true
  # flow_logs_destination_type = "cloud-watch-logs"
  # flow_logs_destination      = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/tgw/corp-hub"
  # flow_logs_iam_role_arn     = "arn:aws:iam::123456789012:role/tgw-flow-logs"

  # ---------------------------------------------------------------------------
  # Optional: throughput alarms. Uncomment to enable.
  # ---------------------------------------------------------------------------
  # alarm_emails          = ["netops@example.com"]
  # alarm_bytes_threshold = 10737418240 # 10 GiB per 5-minute period

  tags = {
    Environment = "all"
    ManagedBy   = "terraform"
    Project     = "network-hub"
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "transit_gateway_id" {
  value = module.tgw.transit_gateway_id
}

output "transit_gateway_arn" {
  value = module.tgw.transit_gateway_arn
}

output "route_table_ids" {
  value = module.tgw.route_table_ids
}

output "vpc_attachment_ids" {
  value = module.tgw.vpc_attachment_ids
}

output "ram_resource_share_arn" {
  value = module.tgw.ram_resource_share_arn
}
