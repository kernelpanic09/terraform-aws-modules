# terraform-aws-vpc

Terraform module for a fully featured AWS VPC with public and private subnets across multiple availability zones. Designed for environments where high availability, security hardening, and operational observability are required from day one.

## Usage

```hcl
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
```

This creates:

- A `/16` VPC with DNS support and DNS hostnames enabled
- 3 public subnets (`10.0.0.0/24`, `10.0.1.0/24`, `10.0.2.0/24`) across 3 AZs
- 3 private subnets (`10.0.3.0/24`, `10.0.4.0/24`, `10.0.5.0/24`) across the same 3 AZs
- 1 Internet Gateway
- 3 NAT Gateways with Elastic IPs (one per AZ for fault isolation)
- 1 shared public route table, 3 private route tables each pointing to their respective NAT
- A hardened default security group with no ingress or egress rules
- VPC Flow Logs to `/aws/vpc/flow-logs/production` with 30-day retention

### Cost-optimized (non-production)

Set `single_nat_gateway = true` to provision a single NAT Gateway shared across all private subnets. This reduces NAT costs at the expense of cross-AZ fault isolation.

```hcl
module "vpc" {
  source = "../../modules/vpc"

  name               = "staging"
  vpc_cidr           = "10.1.0.0/16"
  az_count           = 2
  single_nat_gateway = true
  enable_flow_logs   = false

  tags = {
    Environment = "staging"
  }
}
```

## Inputs

| Name | Type | Default | Required | Description |
|------|------|---------|----------|-------------|
| `name` | `string` | n/a | yes | Name prefix applied to all resources. Must be 1 to 32 characters. |
| `vpc_cidr` | `string` | `"10.0.0.0/16"` | no | CIDR block for the VPC. Must be a valid IPv4 CIDR. |
| `az_count` | `number` | `3` | no | Number of availability zones to use. Must be between 1 and 6 and not exceed the AZ count in your region. |
| `subnet_newbits` | `number` | `8` | no | Bits added to the VPC prefix to calculate subnet CIDRs. For a `/16` VPC, `8` yields `/24` subnets. |
| `single_nat_gateway` | `bool` | `false` | no | Provision a single shared NAT Gateway instead of one per AZ. Useful for non-production cost savings. |
| `enable_flow_logs` | `bool` | `true` | no | Enable VPC Flow Logs to CloudWatch Logs. Creates a log group, IAM role, and inline policy. |
| `flow_log_retention_days` | `number` | `30` | no | Retention period in days for the Flow Logs CloudWatch log group. |
| `tags` | `map(string)` | `{}` | no | Additional tags merged onto all resources. The module always adds `ManagedBy = "terraform"` and `Module = "vpc"`. |

## Outputs

| Name | Description |
|------|-------------|
| `vpc_id` | ID of the VPC. |
| `vpc_cidr` | CIDR block of the VPC. |
| `public_subnet_ids` | Ordered list of public subnet IDs, one per AZ. |
| `private_subnet_ids` | Ordered list of private subnet IDs, one per AZ. |
| `public_subnet_cidrs` | Ordered list of public subnet CIDR blocks. |
| `private_subnet_cidrs` | Ordered list of private subnet CIDR blocks. |
| `nat_gateway_ids` | List of NAT Gateway IDs. |
| `nat_gateway_ips` | List of Elastic IP addresses associated with NAT Gateways. |
| `internet_gateway_id` | ID of the Internet Gateway. |
| `public_route_table_id` | ID of the shared public route table. |
| `private_route_table_ids` | List of private route table IDs (one per AZ, or one if `single_nat_gateway = true`). |
| `default_security_group_id` | ID of the hardened default security group (no ingress or egress rules). |
| `flow_log_group_name` | CloudWatch log group name for Flow Logs. Empty string when `enable_flow_logs = false`. |
| `availability_zones` | List of AZ names used by the module. |

## Requirements

| Name | Version |
|------|---------|
| Terraform | `>= 1.5` |
| AWS Provider | `>= 5.0` |

## Security Notes

The default security group is explicitly overridden to have no ingress or egress rules. AWS creates default security groups with an "allow all" egress rule and a self-referencing ingress rule. This module removes both, preventing resources inadvertently placed in the default group from having unexpected network access.

Flow Logs capture `ALL` traffic (accepted and rejected). The IAM role follows least-privilege and grants only the CloudWatch Logs actions required for flow log delivery.
