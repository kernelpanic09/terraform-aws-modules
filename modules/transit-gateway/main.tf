# ---------------------------------------------------------------------------
# Locals: pre-process variable inputs into maps that other resources use for
# for_each and cross-referencing. Names stay names throughout the variable
# interface; IDs are resolved here via resource attribute references.
# ---------------------------------------------------------------------------

locals {
  # Flatten route_table_propagations into a list of unique (attachment, rt) pairs.
  # Terraform needs a flat map for for_each, so we key by "attachment_name:rt_name".
  propagation_pairs = flatten([
    for att in var.vpc_attachments : [
      for rt_name in att.route_table_propagations : {
        key          = "${att.name}:${rt_name}"
        att_name     = att.name
        rt_name      = rt_name
      }
    ]
  ])

  propagation_map = {
    for pair in local.propagation_pairs : pair.key => pair
  }

  # Build a flat map for static routes so we can for_each over them.
  # Key includes route_table_name + cidr to allow multiple routes per RT.
  static_route_map = {
    for idx, route in var.static_routes :
    "${route.route_table_name}:${route.destination_cidr_block}" => route
  }

  # Determine which principals RAM should share with. The org itself is
  # represented by its organization ARN, fetched via data source when
  # share_with_organization = true.
  ram_principals = var.enable_ram_sharing ? concat(
    var.share_with_organization ? [data.aws_organizations_organization.this[0].arn] : [],
    var.share_principals
  ) : []

  # Alarm resources only created when alarm_emails is non-empty.
  create_alarms = length(var.alarm_emails) > 0
}

# ---------------------------------------------------------------------------
# Transit Gateway
# ---------------------------------------------------------------------------

resource "aws_ec2_transit_gateway" "this" {
  description = "${var.name} transit gateway"

  amazon_side_asn                 = var.amazon_side_asn
  dns_support                     = "enable"
  vpn_ecmp_support                = "enable"
  multicast_support               = var.enable_multicast ? "enable" : "disable"
  auto_accept_shared_attachments  = var.auto_accept_shared_attachments ? "enable" : "disable"

  # We manage all route table associations and propagations explicitly, so we
  # disable the default behaviour that auto-associates every attachment.
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"

  tags = merge(var.tags, { Name = var.name })
}

# ---------------------------------------------------------------------------
# Route tables
# ---------------------------------------------------------------------------

resource "aws_ec2_transit_gateway_route_table" "this" {
  for_each = { for rt in var.route_tables : rt.name => rt }

  transit_gateway_id = aws_ec2_transit_gateway.this.id

  tags = merge(
    var.tags,
    each.value.tags,
    { Name = "${var.name}-${each.key}" }
  )
}

# ---------------------------------------------------------------------------
# VPC attachments
# ---------------------------------------------------------------------------

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  for_each = { for att in var.vpc_attachments : att.name => att }

  transit_gateway_id = aws_ec2_transit_gateway.this.id
  vpc_id             = each.value.vpc_id
  subnet_ids         = each.value.subnet_ids

  dns_support                                 = each.value.dns_support ? "enable" : "disable"
  ipv6_support                                = each.value.ipv6_support ? "enable" : "disable"
  appliance_mode_support                      = each.value.appliance_mode_support ? "enable" : "disable"
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = merge(
    var.tags,
    each.value.tags,
    { Name = "${var.name}-${each.key}" }
  )
}

# ---------------------------------------------------------------------------
# Route table associations
# Each VPC attachment is associated with exactly one route table. Association
# controls what the VPC is allowed to route TO (via the RT's routes).
# ---------------------------------------------------------------------------

resource "aws_ec2_transit_gateway_route_table_association" "this" {
  for_each = { for att in var.vpc_attachments : att.name => att }

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this[each.value.route_table_association].id
}

# ---------------------------------------------------------------------------
# Route table propagations
# Each propagation entry causes the VPC's CIDR to appear as a route in the
# target route table, making the VPC reachable from any attachment in that RT.
# A VPC can propagate into multiple route tables.
# ---------------------------------------------------------------------------

resource "aws_ec2_transit_gateway_route_table_propagation" "this" {
  for_each = local.propagation_map

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.value.att_name].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this[each.value.rt_name].id
}

# ---------------------------------------------------------------------------
# Static routes
# ---------------------------------------------------------------------------

resource "aws_ec2_transit_gateway_route" "this" {
  for_each = local.static_route_map

  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this[each.value.route_table_name].id
  destination_cidr_block         = each.value.destination_cidr_block
  blackhole                      = each.value.blackhole

  # When blackhole = true, no attachment is needed. When false, look up the
  # attachment ID by name from the vpc_attachments map.
  transit_gateway_attachment_id = each.value.blackhole ? null : (
    each.value.attachment_name != null
    ? aws_ec2_transit_gateway_vpc_attachment.this[each.value.attachment_name].id
    : null
  )
}

# ---------------------------------------------------------------------------
# Resource Access Manager (RAM) sharing
# ---------------------------------------------------------------------------

data "aws_organizations_organization" "this" {
  count = var.enable_ram_sharing && var.share_with_organization ? 1 : 0
}

resource "aws_ram_resource_share" "this" {
  count = var.enable_ram_sharing ? 1 : 0

  name                      = "${var.name}-tgw-share"
  allow_external_principals = false

  tags = merge(var.tags, { Name = "${var.name}-tgw-share" })
}

resource "aws_ram_resource_association" "tgw" {
  count = var.enable_ram_sharing ? 1 : 0

  resource_share_arn = aws_ram_resource_share.this[0].arn
  resource_arn       = aws_ec2_transit_gateway.this.arn
}

resource "aws_ram_principal_association" "this" {
  for_each = var.enable_ram_sharing ? toset(local.ram_principals) : toset([])

  resource_share_arn = aws_ram_resource_share.this[0].arn
  principal          = each.value
}

# ---------------------------------------------------------------------------
# Flow logs
# ---------------------------------------------------------------------------

resource "aws_flow_log" "tgw" {
  count = var.enable_flow_logs ? 1 : 0

  # Transit Gateway flow logs use transit_gateway_id, not vpc_id
  transit_gateway_id   = aws_ec2_transit_gateway.this.id
  traffic_type         = var.flow_logs_traffic_type
  log_destination_type = var.flow_logs_destination_type
  log_destination      = var.flow_logs_destination
  iam_role_arn         = var.flow_logs_destination_type == "cloud-watch-logs" ? var.flow_logs_iam_role_arn : null

  tags = merge(var.tags, { Name = "${var.name}-tgw-flow-logs" })
}

# ---------------------------------------------------------------------------
# CloudWatch alarms for byte throughput
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "alarms" {
  count = local.create_alarms ? 1 : 0

  name = "${var.name}-tgw-alarms"
  tags = merge(var.tags, { Name = "${var.name}-tgw-alarms" })
}

resource "aws_sns_topic_subscription" "email" {
  for_each = local.create_alarms ? toset(var.alarm_emails) : toset([])

  topic_arn = aws_sns_topic.alarms[0].arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_cloudwatch_metric_alarm" "bytes_in" {
  count = local.create_alarms ? 1 : 0

  alarm_name          = "${var.name}-tgw-bytes-in-high"
  alarm_description   = "Transit Gateway BytesIn exceeded threshold for ${var.alarm_evaluation_periods} consecutive 5-minute periods."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  metric_name         = "BytesIn"
  namespace           = "AWS/TransitGateway"
  period              = 300
  statistic           = "Sum"
  threshold           = var.alarm_bytes_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    TransitGateway = aws_ec2_transit_gateway.this.id
  }

  alarm_actions = [aws_sns_topic.alarms[0].arn]
  ok_actions    = [aws_sns_topic.alarms[0].arn]

  tags = merge(var.tags, { Name = "${var.name}-tgw-bytes-in-high" })
}

resource "aws_cloudwatch_metric_alarm" "bytes_out" {
  count = local.create_alarms ? 1 : 0

  alarm_name          = "${var.name}-tgw-bytes-out-high"
  alarm_description   = "Transit Gateway BytesOut exceeded threshold for ${var.alarm_evaluation_periods} consecutive 5-minute periods."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  metric_name         = "BytesOut"
  namespace           = "AWS/TransitGateway"
  period              = 300
  statistic           = "Sum"
  threshold           = var.alarm_bytes_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    TransitGateway = aws_ec2_transit_gateway.this.id
  }

  alarm_actions = [aws_sns_topic.alarms[0].arn]
  ok_actions    = [aws_sns_topic.alarms[0].arn]

  tags = merge(var.tags, { Name = "${var.name}-tgw-bytes-out-high" })
}
