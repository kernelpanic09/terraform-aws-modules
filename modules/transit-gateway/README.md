# transit-gateway

A Terraform module for AWS Transit Gateway hub-and-spoke networking. It creates the TGW, route tables, VPC attachments, associations, propagations, static routes, RAM sharing, flow logs, and CloudWatch alarms.

## How Transit Gateway routing works

Understanding associations and propagations is essential before using this module.

**Association** connects an attachment to one route table. That route table determines what the attached VPC can reach. An attachment can only be associated with one route table at a time.

**Propagation** makes an attachment's VPC CIDR appear as a route in a route table. A VPC can propagate its CIDR into multiple route tables, which makes it reachable from all attachments using those tables.

Example: if the prod VPC propagates into the shared-services route table but NOT the non-prod route table, then shared-services can reach prod, but non-prod cannot.

**Static routes** let you override or extend what propagation gives you. The most common use is a `0.0.0.0/0` default route in workload route tables pointing at a shared-services attachment for centralized internet egress.

## Hub-and-spoke pattern

This is the pattern the example implements:

```
                        ┌──────────────────────┐
                        │   Transit Gateway    │
                        │                      │
          ┌─────────────┤  ┌─────────────────┐ ├──────────────┐
          │             │  │  shared-svcs RT │ │              │
          │             │  │  (knows all)    │ │              │
          │             │  └─────────────────┘ │              │
          │             │                      │              │
   ┌──────▼──────┐      │  ┌─────────────────┐ │      ┌───────▼──────┐
   │  Shared     │      │  │    prod RT      │ │      │  Non-prod    │
   │  Services   │      │  │  knows shared   │ │      │  VPC         │
   │  VPC        │      │  │  0/0 → shared   │ │      │              │
   │  (hub)      │      │  └─────────────────┘ │      └──────────────┘
   └─────────────┘      │                      │
                        │  ┌─────────────────┐ │      ┌──────────────┐
                        │  │  non-prod RT    │ │      │  Prod VPC    │
                        │  │  knows shared   ├─┼──────►              │
                        │  │  0/0 → shared   │ │      │              │
                        │  └─────────────────┘ │      └──────────────┘
                        └──────────────────────┘
```

Prod and non-prod don't see each other's routes. Both route their default traffic through shared-services. Shared-services sees everything.

## Usage

```hcl
module "tgw" {
  source = "./module"

  name            = "corp-hub"
  amazon_side_asn = 64512

  route_tables = [
    { name = "shared-services" },
    { name = "prod" },
    { name = "non-prod" },
  ]

  vpc_attachments = [
    {
      name                     = "shared-services"
      vpc_id                   = "vpc-abc123"
      subnet_ids               = ["subnet-aaa", "subnet-bbb"]
      route_table_association  = "shared-services"
      route_table_propagations = ["shared-services", "prod", "non-prod"]
    },
    {
      name                     = "prod"
      vpc_id                   = "vpc-def456"
      subnet_ids               = ["subnet-ccc", "subnet-ddd"]
      route_table_association  = "prod"
      route_table_propagations = ["shared-services"]
    },
    {
      name                     = "non-prod"
      vpc_id                   = "vpc-ghi789"
      subnet_ids               = ["subnet-eee", "subnet-fff"]
      route_table_association  = "non-prod"
      route_table_propagations = ["shared-services"]
    },
  ]

  static_routes = [
    {
      route_table_name       = "prod"
      destination_cidr_block = "0.0.0.0/0"
      attachment_name        = "shared-services"
    },
    {
      route_table_name       = "non-prod"
      destination_cidr_block = "0.0.0.0/0"
      attachment_name        = "shared-services"
    },
  ]

  enable_ram_sharing      = true
  share_with_organization = true

  tags = {
    ManagedBy = "terraform"
  }
}
```

## VPC route table changes (your responsibility)

This module creates the Transit Gateway side of routing. You also need to update the VPC route tables in each spoke VPC to send traffic destined for other VPCs (or the internet, via centralized egress) through the TGW attachment. The module outputs `vpc_attachment_ids` as a map so you can reference them:

```hcl
resource "aws_route" "to_tgw" {
  route_table_id         = aws_route_table.prod_private.id
  destination_cidr_block = "10.0.0.0/8"
  transit_gateway_id     = module.tgw.transit_gateway_id
}
```

## RAM sharing and cross-account attachments

When `enable_ram_sharing = true`, the TGW is shared via AWS Resource Access Manager.

If `share_with_organization = true`, the entire Organization is added as a principal. Member accounts can then create VPC attachments to the TGW. You'll also want `auto_accept_shared_attachments = true` (or set it to false and approve manually).

RAM sharing requires Organizations integration to be enabled in RAM. You do this once from the management account: AWS console, Resource Access Manager, Settings, Enable sharing with AWS Organizations.

## Flow logs

Set `enable_flow_logs = true` and provide a destination ARN. For CloudWatch Logs you also need an IAM role:

```hcl
enable_flow_logs           = true
flow_logs_destination_type = "cloud-watch-logs"
flow_logs_destination      = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/tgw/corp-hub"
flow_logs_iam_role_arn     = aws_iam_role.tgw_flow_logs.arn
```

For S3, omit the role:

```hcl
enable_flow_logs           = true
flow_logs_destination_type = "s3"
flow_logs_destination      = "arn:aws:s3:::my-flow-logs-bucket/tgw/"
```

## Alarms

Provide one or more email addresses to get notified when BytesIn or BytesOut spike above the threshold:

```hcl
alarm_emails          = ["netops@example.com"]
alarm_bytes_threshold = 10737418240 # 10 GiB per 5-minute period
```

Each email address gets an SNS subscription. AWS will send a confirmation email before the subscription activates.

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.5.0 |
| aws | >= 5.0.0 |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| name | Name prefix for all resources. | `string` | | yes |
| amazon_side_asn | BGP ASN for the TGW. | `number` | `64512` | no |
| enable_multicast | Enable multicast on the TGW. | `bool` | `false` | no |
| auto_accept_shared_attachments | Auto-accept cross-account attachments. | `bool` | `false` | no |
| route_tables | List of route table definitions. Each needs a unique `name`. | `list(object)` | `[]` | no |
| vpc_attachments | List of VPC attachments with routing config. | `list(object)` | `[]` | no |
| static_routes | Static routes to insert into route tables. | `list(object)` | `[]` | no |
| enable_ram_sharing | Share the TGW via RAM. | `bool` | `false` | no |
| share_with_organization | Add the whole AWS Org as a RAM principal. | `bool` | `false` | no |
| share_principals | Additional principals to add to the RAM share. | `list(string)` | `[]` | no |
| enable_flow_logs | Enable TGW flow logs. | `bool` | `false` | no |
| flow_logs_destination_type | `s3` or `cloud-watch-logs`. | `string` | `"cloud-watch-logs"` | no |
| flow_logs_destination | ARN of the S3 bucket or CloudWatch log group. | `string` | `null` | no |
| flow_logs_iam_role_arn | IAM role ARN for CloudWatch Logs delivery. | `string` | `null` | no |
| flow_logs_traffic_type | `ACCEPT`, `REJECT`, or `ALL`. | `string` | `"ALL"` | no |
| alarm_emails | Email addresses for throughput alarms. | `list(string)` | `[]` | no |
| alarm_bytes_threshold | Bytes per 5 minutes that triggers an alarm. | `number` | `10737418240` | no |
| alarm_evaluation_periods | Consecutive breach periods before alarming. | `number` | `3` | no |
| tags | Tags applied to all resources. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| transit_gateway_id | ID of the Transit Gateway. |
| transit_gateway_arn | ARN of the Transit Gateway. |
| transit_gateway_owner_id | Account ID that owns the TGW. |
| transit_gateway_association_default_route_table_id | Default association route table ID (not used by this module). |
| route_table_ids | Map of route table name to ID. |
| route_table_arns | Map of route table name to ARN. |
| vpc_attachment_ids | Map of attachment name to attachment ID. |
| vpc_attachment_arns | Map of attachment name to attachment ARN. |
| ram_resource_share_arn | ARN of the RAM resource share. Null if sharing is disabled. |
| flow_log_id | ID of the flow log resource. Null if flow logs are disabled. |
| alarm_sns_topic_arn | ARN of the alarms SNS topic. Null if alarm_emails is empty. |
| alarm_bytes_in_arn | ARN of the BytesIn alarm. |
| alarm_bytes_out_arn | ARN of the BytesOut alarm. |

## Known limitations

- TGW flow logs are currently in preview for some regions. Check regional availability before enabling.
- Changing `route_table_association` for an existing attachment requires Terraform to destroy and recreate the association resource, not the attachment itself.
- Multicast domains are not managed by this module. Enable `enable_multicast = true` and manage multicast domains separately if needed.
- `static_routes` uses `route_table_name:destination_cidr_block` as its internal map key. Don't use the same CIDR twice in the same route table.
